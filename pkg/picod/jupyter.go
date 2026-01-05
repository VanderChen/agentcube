package picod

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"k8s.io/klog/v2"
)

// JupyterManager manages Jupyter Server and kernel lifecycle
type JupyterManager struct {
	serverCmd      *exec.Cmd
	serverURL      string
	kernelID       string
	wsConn         *websocket.Conn
	mutex          sync.Mutex // Ensures single execution at a time
	resetMutex     sync.Mutex // Ensures reset completes before next execution
	token          string
	workspaceDir   string
	httpClient     *http.Client
	stopPingPong   chan struct{} // Signal to stop ping/pong goroutine
	reconnectMutex sync.Mutex    // Protects reconnection logic
	isReconnecting bool          // Flag to indicate reconnection in progress
}

// ExecutionResult captures Python execution output
type ExecutionResult struct {
	Output         string `json:"output"`
	Error          string `json:"error"`
	Status         string `json:"status"` // "ok" or "error"
	ExecutionCount int    `json:"execution_count"`
}

// NewJupyterManager creates and initializes Jupyter Server
func NewJupyterManager(workspaceDir string) (*JupyterManager, error) {
	jm := &JupyterManager{
		serverURL:    "http://127.0.0.1:8888",
		token:        generateJupyterToken(),
		workspaceDir: workspaceDir,
		httpClient:   &http.Client{Timeout: 120 * time.Second},
	}

	if err := jm.startJupyterServer(); err != nil {
		return nil, fmt.Errorf("failed to start Jupyter Server: %w", err)
	}

	if err := jm.createKernel(); err != nil {
		return nil, fmt.Errorf("failed to create kernel: %w", err)
	}

	if err := jm.connectWebSocket(); err != nil {
		return nil, fmt.Errorf("failed to connect WebSocket: %w", err)
	}

	// Start ping/pong keepalive mechanism
	jm.stopPingPong = make(chan struct{})
	go jm.pingPongKeepalive()

	klog.Info("Jupyter Server initialized successfully")
	return jm, nil
}

// startJupyterServer launches Jupyter Server process
func (jm *JupyterManager) startJupyterServer() error {
	// Ensure workspace directory exists
	if err := os.MkdirAll(jm.workspaceDir, 0755); err != nil {
		return fmt.Errorf("failed to create workspace directory: %w", err)
	}

	cmd := exec.Command(
		"jupyter-server",
		"--no-browser",
		"--ip=127.0.0.1",
		"--port=8888",
		"--allow-root", // Required for running in container as root
		fmt.Sprintf("--ServerApp.token=%s", jm.token),
		fmt.Sprintf("--ServerApp.root_dir=%s", jm.workspaceDir),
		"--ServerApp.allow_origin=*",
	)

	// Capture output for debugging
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	klog.Infof("Starting Jupyter Server with command: %v", cmd.Args)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start jupyter server: %w", err)
	}

	jm.serverCmd = cmd

	// Wait for server to be ready
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	return jm.waitForServer(ctx)
}

// waitForServer polls until Jupyter Server is responsive
func (jm *JupyterManager) waitForServer(ctx context.Context) error {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for Jupyter Server")
		case <-ticker.C:
			resp, err := http.Get(fmt.Sprintf("%s/api?token=%s", jm.serverURL, jm.token))
			if err == nil && resp.StatusCode == http.StatusOK {
				resp.Body.Close()
				return nil
			}
			if resp != nil {
				resp.Body.Close()
			}
		}
	}
}

// createKernel creates a persistent Python kernel
func (jm *JupyterManager) createKernel() error {
	reqBody := map[string]string{"name": "python3"}
	bodyBytes, _ := json.Marshal(reqBody)

	resp, err := http.Post(
		fmt.Sprintf("%s/api/kernels?token=%s", jm.serverURL, jm.token),
		"application/json",
		bytes.NewBuffer(bodyBytes),
	)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("failed to create kernel: status %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return err
	}

	jm.kernelID = result["id"].(string)
	klog.Infof("Created kernel: %s", jm.kernelID)
	return nil
}

// connectWebSocket establishes WebSocket connection to kernel
func (jm *JupyterManager) connectWebSocket() error {
	wsURL := fmt.Sprintf("ws://127.0.0.1:8888/api/kernels/%s/channels?token=%s",
		jm.kernelID, jm.token)

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("failed to dial WebSocket: %w", err)
	}

	// Set up pong handler
	conn.SetPongHandler(func(appData string) error {
		klog.V(5).Infof("Received pong from kernel %s", jm.kernelID)
		return nil
	})

	jm.wsConn = conn
	klog.Infof("WebSocket connected to kernel %s", jm.kernelID)
	return nil
}

// pingPongKeepalive sends periodic ping messages to keep WebSocket alive
func (jm *JupyterManager) pingPongKeepalive() {
	// Ping interval should be less than Jupyter's websocket_ping_timeout (default 90s)
	// Using 60 seconds to ensure we send ping well before timeout
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			jm.reconnectMutex.Lock()
			if jm.wsConn != nil && !jm.isReconnecting {
				// Write deadline should be shorter than ping interval
				if err := jm.wsConn.WriteControl(websocket.PingMessage, []byte{}, time.Now().Add(30*time.Second)); err != nil {
					klog.Warningf("Failed to send ping to kernel %s: %v, attempting reconnection", jm.kernelID, err)
					jm.reconnectMutex.Unlock()
					jm.reconnectWebSocket()
					continue
				}
				klog.V(5).Infof("Sent ping to kernel %s", jm.kernelID)
			}
			jm.reconnectMutex.Unlock()
		case <-jm.stopPingPong:
			klog.Info("Stopping ping/pong keepalive")
			return
		}
	}
}

// reconnectWebSocket attempts to reconnect the WebSocket connection
func (jm *JupyterManager) reconnectWebSocket() {
	jm.reconnectMutex.Lock()
	if jm.isReconnecting {
		jm.reconnectMutex.Unlock()
		return // Already reconnecting
	}
	jm.isReconnecting = true
	jm.reconnectMutex.Unlock()

	defer func() {
		jm.reconnectMutex.Lock()
		jm.isReconnecting = false
		jm.reconnectMutex.Unlock()
	}()

	klog.Warningf("WebSocket connection lost, attempting to reconnect to kernel %s", jm.kernelID)

	// Close existing connection if any
	if jm.wsConn != nil {
		jm.wsConn.Close()
		jm.wsConn = nil
	}

	// Retry connection with exponential backoff
	maxRetries := 10
	baseDelay := 1 * time.Second
	maxDelay := 60 * time.Second

	for attempt := 1; attempt <= maxRetries; attempt++ {
		klog.Infof("Reconnection attempt %d/%d for kernel %s", attempt, maxRetries, jm.kernelID)

		if err := jm.connectWebSocket(); err != nil {
			klog.Errorf("Reconnection attempt %d failed: %v", attempt, err)

			// Calculate exponential backoff delay
			delay := time.Duration(1<<uint(attempt-1)) * baseDelay
			if delay > maxDelay {
				delay = maxDelay
			}

			klog.Infof("Waiting %v before next reconnection attempt", delay)
			time.Sleep(delay)
			continue
		}

		klog.Infof("Successfully reconnected WebSocket to kernel %s", jm.kernelID)
		return
	}

	klog.Errorf("Failed to reconnect WebSocket after %d attempts, kernel %s may be unavailable", maxRetries, jm.kernelID)
}

// ExecuteCode executes Python code and returns results (no timeout - blocks until completion)
func (jm *JupyterManager) ExecuteCode(code string) (*ExecutionResult, error) {
	klog.V(4).Infof("[ExecuteCode] Starting execution, waiting for reset to complete")

	// Wait for any pending reset to complete before starting new execution
	jm.resetMutex.Lock()
	klog.V(4).Infof("[ExecuteCode] Reset mutex acquired, reset is complete")
	jm.resetMutex.Unlock()

	// Requirement 3: Acquire mutex for exclusive execution
	klog.V(4).Infof("[ExecuteCode] Acquiring execution mutex")
	jm.mutex.Lock()
	defer func() {
		klog.V(4).Infof("[ExecuteCode] Releasing execution mutex")
		jm.mutex.Unlock()
	}()

	klog.V(4).Infof("[ExecuteCode] Execution mutex acquired, executing code")
	result, err := jm.executeViaWebSocket(code)
	if err != nil {
		klog.Errorf("[ExecuteCode] Execution failed: %v", err)
		return result, err
	}

	klog.V(4).Infof("[ExecuteCode] Execution completed successfully, starting async reset")
	// Requirement 2: Soft reset environment using %reset -f asynchronously
	// The reset will block the next execution but not the current response
	go jm.asyncSoftReset()

	return result, err
}

// asyncSoftReset performs soft reset asynchronously but blocks next execution
func (jm *JupyterManager) asyncSoftReset() {
	klog.V(4).Infof("[asyncSoftReset] Starting async reset, acquiring reset mutex first")

	// Acquire reset mutex first to signal that reset is in progress
	jm.resetMutex.Lock()
	defer func() {
		klog.V(4).Infof("[asyncSoftReset] Releasing reset mutex")
		jm.resetMutex.Unlock()
	}()

	klog.V(4).Infof("[asyncSoftReset] Reset mutex acquired, now waiting for execution mutex")

	// Then wait for current execution to complete by acquiring execution mutex
	jm.mutex.Lock()
	klog.V(4).Infof("[asyncSoftReset] Execution mutex acquired, performing reset")

	resetCode := "%reset -f"
	if _, err := jm.executeViaWebSocket(resetCode); err != nil {
		klog.Errorf("[asyncSoftReset] Failed to soft reset kernel: %v", err)
	} else {
		klog.V(4).Infof("[asyncSoftReset] Reset completed successfully")
	}

	klog.V(4).Infof("[asyncSoftReset] Releasing execution mutex")
	jm.mutex.Unlock()
}

// executeViaWebSocket executes code via Jupyter WebSocket (no timeout)
func (jm *JupyterManager) executeViaWebSocket(code string) (*ExecutionResult, error) {
	// Check if reconnection is needed
	jm.reconnectMutex.Lock()
	if jm.wsConn == nil {
		jm.reconnectMutex.Unlock()
		return nil, fmt.Errorf("WebSocket connection is not available")
	}
	jm.reconnectMutex.Unlock()

	// Generate message ID
	msgID := uuid.New().String()
	klog.V(4).Infof("[executeViaWebSocket] Generated message ID: %s for code execution", msgID)

	// Create execute_request message
	executeMsg := map[string]interface{}{
		"header": map[string]interface{}{
			"msg_id":   msgID,
			"username": "picod",
			"session":  jm.kernelID,
			"msg_type": "execute_request",
			"version":  "5.3",
		},
		"parent_header": map[string]interface{}{},
		"metadata":      map[string]interface{}{},
		"content": map[string]interface{}{
			"code":             code,
			"silent":           false,
			"store_history":    true,
			"user_expressions": map[string]interface{}{},
			"allow_stdin":      false,
			"stop_on_error":    true,
		},
		"buffers": []interface{}{},
	}

	// Send execute request
	klog.V(4).Infof("[executeViaWebSocket] Sending execute request via WebSocket")
	jm.reconnectMutex.Lock()
	err := jm.wsConn.WriteJSON(executeMsg)
	jm.reconnectMutex.Unlock()

	if err != nil {
		klog.Errorf("[executeViaWebSocket] Failed to write to WebSocket: %v, attempting reconnection", err)
		jm.reconnectWebSocket()
		return nil, fmt.Errorf("failed to send execute request: %w", err)
	}
	klog.V(4).Infof("[executeViaWebSocket] Execute request sent successfully")

	// Collect results
	result := &ExecutionResult{Status: "ok"}
	var outputBuffer, errorBuffer strings.Builder
	executionCount := 0

	// Read messages until we get execute_reply
	for {
		var msg map[string]interface{}
		jm.reconnectMutex.Lock()
		err := jm.wsConn.ReadJSON(&msg)
		jm.reconnectMutex.Unlock()

		if err != nil {
			klog.Errorf("Failed to read message from WebSocket: %v, attempting reconnection", err)
			jm.reconnectWebSocket()
			return nil, fmt.Errorf("failed to read message: %w", err)
		}

		header, ok := msg["header"].(map[string]interface{})
		if !ok {
			continue
		}

		msgType, ok := header["msg_type"].(string)
		if !ok {
			continue
		}

		content, _ := msg["content"].(map[string]interface{})

		switch msgType {
		case "stream":
			if name, ok := content["name"].(string); ok {
				if text, ok := content["text"].(string); ok {
					if name == "stdout" {
						outputBuffer.WriteString(text)
					} else if name == "stderr" {
						errorBuffer.WriteString(text)
					}
				}
			}

		case "execute_result", "display_data":
			if data, ok := content["data"].(map[string]interface{}); ok {
				if textPlain, ok := data["text/plain"].(string); ok {
					outputBuffer.WriteString(textPlain)
					outputBuffer.WriteString("\n")
				}
			}
			if count, ok := content["execution_count"].(float64); ok {
				executionCount = int(count)
			}

		case "error":
			result.Status = "error"
			if ename, ok := content["ename"].(string); ok {
				errorBuffer.WriteString(ename)
				errorBuffer.WriteString(": ")
			}
			if evalue, ok := content["evalue"].(string); ok {
				errorBuffer.WriteString(evalue)
				errorBuffer.WriteString("\n")
			}
			if traceback, ok := content["traceback"].([]interface{}); ok {
				for _, line := range traceback {
					if lineStr, ok := line.(string); ok {
						errorBuffer.WriteString(lineStr)
						errorBuffer.WriteString("\n")
					}
				}
			}

		case "execute_reply":
			if count, ok := content["execution_count"].(float64); ok {
				executionCount = int(count)
			}
			result.Output = outputBuffer.String()
			result.Error = errorBuffer.String()
			result.ExecutionCount = executionCount
			return result, nil
		}
	}
}

// Shutdown gracefully stops Jupyter Server
func (jm *JupyterManager) Shutdown() error {
	// Stop ping/pong keepalive
	if jm.stopPingPong != nil {
		close(jm.stopPingPong)
	}

	// Close WebSocket connection
	if jm.wsConn != nil {
		jm.wsConn.Close()
	}

	// Kill Jupyter server process
	if jm.serverCmd != nil && jm.serverCmd.Process != nil {
		if err := jm.serverCmd.Process.Kill(); err != nil {
			return err
		}
	}

	return nil
}

// generateJupyterToken generates a unique token for Jupyter Server
func generateJupyterToken() string {
	return fmt.Sprintf("picod-%d", time.Now().Unix())
}

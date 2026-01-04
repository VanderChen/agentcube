package picod

import (
	"bytes"
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

type JupyterManager struct {
	serverCmd    *exec.Cmd
	serverURL    string
	kernelID     string
	wsConn       *websocket.Conn
	mutex        sync.Mutex
	resetMutex   sync.Mutex
	token        string
	workspaceDir string
	httpClient   *http.Client
}

type ExecutionResult struct {
	Output         string `json:"output"`
	Error          string `json:"error"`
	Status         string `json:"status"`
	ExecutionCount int    `json:"execution_count"`
}

// --- 初始化部分保持原样，修正了 connectWebSocket 的错误处理 ---

func NewJupyterManager(workspaceDir string) (*JupyterManager, error) {
	jm := &JupyterManager{
		serverURL:    "http://127.0.0.1:8888",
		token:        fmt.Sprintf("picod-%d", time.Now().Unix()),
		workspaceDir: workspaceDir,
		httpClient:   &http.Client{Timeout: 120 * time.Second},
	}

	if err := jm.startJupyterServer(); err != nil {
		return nil, err
	}
	if err := jm.createKernel(); err != nil {
		return nil, err
	}
	if err := jm.ensureConnection(); err != nil {
		return nil, err
	}

	klog.Info("Jupyter Server initialized successfully")
	return jm, nil
}

// ensureConnection 确保 WebSocket 连接可用
func (jm *JupyterManager) ensureConnection() error {
	if jm.wsConn != nil {
		// 发送 Ping 检查连接是否存活
		err := jm.wsConn.WriteMessage(websocket.PingMessage, []byte{})
		if err == nil {
			return nil
		}
		jm.wsConn.Close()
		jm.wsConn = nil
	}

	wsURL := fmt.Sprintf("ws://127.0.0.1:8888/api/kernels/%s/channels?token=%s", jm.kernelID, jm.token)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial failed: %w", err)
	}
	jm.wsConn = conn
	return nil
}

func (jm *JupyterManager) ExecuteCode(code string) (*ExecutionResult, error) {
	jm.resetMutex.Lock()
	jm.resetMutex.Unlock()

	jm.mutex.Lock()
	defer jm.mutex.Unlock()

	// 1. 执行前检查并尝试修复连接
	if err := jm.ensureConnection(); err != nil {
		return nil, fmt.Errorf("failed to maintain connection: %w", err)
	}

	result, err := jm.executeViaWebSocket(code)
	if err != nil {
		// 2. 如果执行中连接断开，强制清理连接以便下次重连
		if websocket.IsCloseError(err, 1005, 1006, 1001) || strings.Contains(err.Error(), "closed") {
			if jm.wsConn != nil {
				jm.wsConn.Close()
				jm.wsConn = nil
			}
		}
		return result, err
	}

	go jm.asyncSoftReset()
	return result, nil
}

func (jm *JupyterManager) executeViaWebSocket(code string) (*ExecutionResult, error) {
	msgID := uuid.New().String()
	executeMsg := map[string]interface{}{
		"header": map[string]interface{}{
			"msg_id":   msgID,
			"username": "picod",
			"session":  uuid.New().String(), // 每次执行建议使用独立 session ID
			"msg_type": "execute_request",
			"version":  "5.3",
		},
		"content": map[string]interface{}{
			"code":          code,
			"silent":        false,
			"store_history": true,
			"stop_on_error": true,
		},
	}

	if err := jm.wsConn.WriteJSON(executeMsg); err != nil {
		return nil, fmt.Errorf("write error: %w", err)
	}

	result := &ExecutionResult{Status: "ok"}
	var outputBuffer, errorBuffer strings.Builder

	// 设置读取超时，防止 Kernel 锁死导致程序挂起
	// jm.wsConn.SetReadDeadline(time.Now().Add(60 * time.Second))

	for {
		var msg map[string]interface{}
		if err := jm.wsConn.ReadJSON(&msg); err != nil {
			return nil, fmt.Errorf("read error (code 1005 possible): %w", err)
		}

		header := msg["header"].(map[string]interface{})
		msgType := header["msg_type"].(string)
		content, _ := msg["content"].(map[string]interface{})

		// 确保只处理属于当前请求的回包
		parentHeader, _ := msg["parent_header"].(map[string]interface{})
		if parentHeader["msg_id"] != msgID {
			continue
		}

		switch msgType {
		case "stream":
			if text, ok := content["text"].(string); ok {
				if content["name"] == "stdout" {
					outputBuffer.WriteString(text)
				} else {
					errorBuffer.WriteString(text)
				}
			}
		case "error":
			result.Status = "error"
			if tb, ok := content["traceback"].([]interface{}); ok {
				for _, line := range tb {
					errorBuffer.WriteString(line.(string) + "\n")
				}
			}
		case "execute_reply":
			result.Output = outputBuffer.String()
			result.Error = errorBuffer.String()
			if count, ok := content["execution_count"].(float64); ok {
				result.ExecutionCount = int(count)
			}
			return result, nil
		}
	}
}

// --- 辅助方法（Jupyter Server 管理） ---

func (jm *JupyterManager) startJupyterServer() error {
	os.MkdirAll(jm.workspaceDir, 0755)
	cmd := exec.Command("jupyter-server", "--no-browser", "--ip=127.0.0.1", "--port=8888",
		"--allow-root", fmt.Sprintf("--ServerApp.token=%s", jm.token),
		fmt.Sprintf("--ServerApp.root_dir=%s", jm.workspaceDir))

	if err := cmd.Start(); err != nil {
		return err
	}
	jm.serverCmd = cmd

	// 等待响应
	for i := 0; i < 20; i++ {
		resp, err := http.Get(fmt.Sprintf("%s/api?token=%s", jm.serverURL, jm.token))
		if err == nil && resp.StatusCode == 200 {
			resp.Body.Close()
			return nil
		}
		time.Sleep(1 * time.Second)
	}
	return fmt.Errorf("jupyter server timeout")
}

func (jm *JupyterManager) createKernel() error {
	data, _ := json.Marshal(map[string]string{"name": "python3"})
	resp, err := http.Post(fmt.Sprintf("%s/api/kernels?token=%s", jm.serverURL, jm.token), "application/json", bytes.NewBuffer(data))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	var res map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&res)
	jm.kernelID = res["id"].(string)
	return nil
}

func (jm *JupyterManager) asyncSoftReset() {
	jm.resetMutex.Lock()
	defer jm.resetMutex.Unlock()

	jm.mutex.Lock()
	defer jm.mutex.Unlock()

	if err := jm.ensureConnection(); err != nil {
		return
	}
	jm.executeViaWebSocket("%reset -f")
}

func (jm *JupyterManager) Shutdown() error {
	if jm.wsConn != nil {
		jm.wsConn.Close()
	}
	if jm.serverCmd != nil && jm.serverCmd.Process != nil {
		return jm.serverCmd.Process.Kill()
	}
	return nil
}

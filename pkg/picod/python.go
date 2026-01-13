package picod

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"time"

	"github.com/gin-gonic/gin"
	"k8s.io/klog/v2"
)

// SimpleRunPythonRequest defines simple Python execution request
type SimpleRunPythonRequest struct {
	Code    string `json:"code" binding:"required"` // Base64 encoded code
	Timeout string `json:"timeout"`                 // Optional: Timeout (e.g., "30s"). Defaults to "5m".
}

// SimpleRunPythonHandler handles simple Python code execution requests
func (s *Server) SimpleRunPythonHandler(c *gin.Context) {
	requestStart := time.Now()
	var req SimpleRunPythonRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Decode base64 code
	decodedBytes, err := base64.StdEncoding.DecodeString(req.Code)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Invalid base64 code",
			"code":  http.StatusBadRequest,
		})
		return
	}
	code := string(decodedBytes)

	// Set timeout
	timeoutDuration := 5 * time.Minute // Default timeout
	if req.Timeout != "" {
		var err error
		timeoutDuration, err = time.ParseDuration(req.Timeout)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": fmt.Sprintf("Invalid timeout format: %v", err),
				"code":  http.StatusBadRequest,
			})
			return
		}
	}

	// Execute code using python -c
	ctx, cancel := context.WithTimeout(context.Background(), timeoutDuration)
	defer cancel()

	cmd := exec.CommandContext(ctx, "python3", "-c", code)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	start := time.Now()
	err = cmd.Run()
	duration := time.Since(start).Seconds()
	endTime := time.Now()

	var exitCode int
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		exitCode = TimeoutExitCode
		stderr.WriteString(fmt.Sprintf("Command timed out after %.0f seconds", timeoutDuration.Seconds()))
	} else if cmd.ProcessState != nil {
		exitCode = cmd.ProcessState.ExitCode()
	} else {
		exitCode = 1
		if err != nil && stderr.Len() == 0 {
			stderr.WriteString(err.Error())
		}
	}

	c.JSON(http.StatusOK, ExecuteResponse{
		Stdout:    stdout.String(),
		Stderr:    stderr.String(),
		ExitCode:  exitCode,
		Duration:  duration,
		StartTime: start,
		EndTime:   endTime,
	})

	klog.Infof("[SimpleRunPythonHandler] Request completed in %.3f seconds, exit_code: %d",
		time.Since(requestStart).Seconds(), exitCode)
}

// RunPythonRequest defines Python execution request
type RunPythonRequest struct {
	Code string `json:"code" binding:"required"`
}

// RunPythonResponse defines Python execution response
type RunPythonResponse struct {
	Output         string  `json:"output"`
	Error          string  `json:"error"`
	Status         string  `json:"status"` // "ok" or "error"
	ExecutionCount int     `json:"execution_count"`
	Duration       float64 `json:"duration"`
}

// RunPythonHandler handles Python code execution requests
func (s *Server) RunPythonHandler(c *gin.Context) {
	requestStart := time.Now()
	klog.V(4).Infof("[RunPythonHandler] Received Python execution request from %s", c.ClientIP())

	// Check if Jupyter Manager is available
	if s.jupyterManager == nil {
		klog.Errorf("[RunPythonHandler] Jupyter Manager not available")
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error":  "Python code execution is not available",
			"code":   http.StatusServiceUnavailable,
			"detail": "Jupyter Server is not initialized. Please ensure jupyter-server is installed.",
		})
		return
	}

	var req RunPythonRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		klog.Errorf("[RunPythonHandler] Failed to parse request: %v", err)
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	klog.V(4).Infof("[RunPythonHandler] Code length: %d bytes", len(req.Code))
	klog.V(4).Infof("[RunPythonHandler] Code preview: %.100s...", req.Code)

	// Execute code without timeout (blocking until completion)
	klog.V(4).Infof("[RunPythonHandler] Starting code execution")
	start := time.Now()
	result, err := s.jupyterManager.ExecuteCode(req.Code)
	duration := time.Since(start).Seconds()
	klog.V(4).Infof("[RunPythonHandler] Code execution completed in %.3f seconds", duration)

	if err != nil {
		klog.Errorf("[RunPythonHandler] Execution failed: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": err.Error(),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	klog.V(4).Infof("[RunPythonHandler] Execution result - Status: %s, ExecutionCount: %d, OutputLen: %d, ErrorLen: %d",
		result.Status, result.ExecutionCount, len(result.Output), len(result.Error))

	c.JSON(http.StatusOK, RunPythonResponse{
		Output:         result.Output,
		Error:          result.Error,
		Status:         result.Status,
		ExecutionCount: result.ExecutionCount,
		Duration:       duration,
	})

	klog.Infof("[RunPythonHandler] Request completed in %.3f seconds, status: %s, execution_count: %d",
		time.Since(requestStart).Seconds(), result.Status, result.ExecutionCount)
	klog.V(4).Infof("[RunPythonHandler] Response sent successfully")
}

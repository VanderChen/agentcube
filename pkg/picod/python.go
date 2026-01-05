package picod

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"k8s.io/klog/v2"
)

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

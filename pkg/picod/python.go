package picod

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
func (s *Server) RunPythonHandler(c *gin.Context) {
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

	// Sanitize code to handle unescaped newlines in string literals
	code = sanitizePythonCode(code)

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

	// Save code to temporary file
	tmpFile, err := os.CreateTemp(s.workspaceDir, "*.py")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to create temporary file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}
	filePath := tmpFile.Name()
	filename := filepath.Base(filePath)

	klog.Infof("[SimpleRunPythonHandler] Saving code to file: %s", filename)
	klog.Infof("[SimpleRunPythonHandler] Code content:\n%s", code)

	defer func() {
		if err := os.Remove(filePath); err != nil {
			klog.Warningf("Failed to remove temporary file %s: %v", filePath, err)
		}
	}()

	if _, err := tmpFile.Write([]byte(code)); err != nil {
		tmpFile.Close()
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to write code to file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}
	if err := tmpFile.Close(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to close temporary file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Execute code using python <file>
	ctx, cancel := context.WithTimeout(context.Background(), timeoutDuration)
	defer cancel()

	cmd := exec.CommandContext(ctx, "python3", filename)
	cmd.Dir = s.workspaceDir

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

// RunPythonFileHandler handles python code execution requests via file upload
func (s *Server) RunPythonFileHandler(c *gin.Context) {
	requestStart := time.Now()

	// Get file from request
	fileHeader, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("Failed to get file: %v", err),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Set timeout
	timeoutDuration := 5 * time.Minute // Default timeout
	timeoutStr := c.PostForm("timeout")
	if timeoutStr != "" {
		timeoutDuration, err = time.ParseDuration(timeoutStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": fmt.Sprintf("Invalid timeout format: %v", err),
				"code":  http.StatusBadRequest,
			})
			return
		}
	}

	// Save code to temporary file
	// We use os.CreateTemp to generate a random filename as requested
	tmpFile, err := os.CreateTemp(s.workspaceDir, "*.py")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to create temporary file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}
	filePath := tmpFile.Name()
	filename := filepath.Base(filePath)

	klog.Infof("[RunPythonFileHandler] Saving uploaded file to: %s", filename)

	defer func() {
		if err := os.Remove(filePath); err != nil {
			klog.Warningf("Failed to remove temporary file %s: %v", filePath, err)
		}
	}()

	// Save uploaded content to temp file
	src, err := fileHeader.Open()
	if err != nil {
		tmpFile.Close()
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to open uploaded file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}
	defer src.Close()

	// Copy content
	if _, err := io.Copy(tmpFile, src); err != nil {
		tmpFile.Close()
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to write code to file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	if err := tmpFile.Close(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to close temporary file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Execute code using python <file>
	ctx, cancel := context.WithTimeout(context.Background(), timeoutDuration)
	defer cancel()

	cmd := exec.CommandContext(ctx, "python3", filename)
	cmd.Dir = s.workspaceDir

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

	klog.Infof("[RunPythonFileHandler] Request completed in %.3f seconds, exit_code: %d",
		time.Since(requestStart).Seconds(), exitCode)
}

// sanitizePythonCode escapes newlines in single/double quoted strings while preserving them in triple-quoted strings
// It also heuristically escapes quotes inside strings that appear to be JSON structures (e.g. s="{"key": "value"}")
func sanitizePythonCode(code string) string {
	var sb strings.Builder
	n := len(code)

	const (
		STATE_NORMAL = iota
		STATE_COMMENT
		STATE_SQ
		STATE_DQ
		STATE_TSQ
		STATE_TDQ
		STATE_DQ_JSON // Special state for strings like "{"..."}"
	)

	state := STATE_NORMAL
	jsonEndIndex := -1

	for i := 0; i < n; i++ {
		char := code[i]

		switch state {
		case STATE_NORMAL:
			if char == '#' {
				state = STATE_COMMENT
				sb.WriteByte(char)
			} else if char == '\'' {
				if i+2 < n && code[i+1] == '\'' && code[i+2] == '\'' {
					state = STATE_TSQ
					sb.WriteString("'''")
					i += 2
				} else {
					state = STATE_SQ
					sb.WriteByte(char)
				}
			} else if char == '"' {
				if i+2 < n && code[i+1] == '"' && code[i+2] == '"' {
					state = STATE_TDQ
					sb.WriteString("\"\"\"")
					i += 2
				} else {
					// Check for JSON string pattern: "{" ... "}"
					jsonEnd := -1
					if i+1 < n && code[i+1] == '{' {
						jsonEnd = findJSONStringEnd(code, i+2)
					}

					if jsonEnd != -1 {
						state = STATE_DQ_JSON
						jsonEndIndex = jsonEnd
						sb.WriteByte(char)
					} else {
						state = STATE_DQ
						sb.WriteByte(char)
					}
				}
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else {
				sb.WriteByte(char)
			}

		case STATE_COMMENT:
			sb.WriteByte(char)
			if char == '\n' {
				state = STATE_NORMAL
			}

		case STATE_SQ:
			if char == '\'' {
				state = STATE_NORMAL
				sb.WriteByte(char)
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else if char == '\n' {
				// Escape newline
				sb.WriteString("\\n")
			} else {
				sb.WriteByte(char)
			}

		case STATE_DQ:
			if char == '"' {
				state = STATE_NORMAL
				sb.WriteByte(char)
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else if char == '\n' {
				// Escape newline
				sb.WriteString("\\n")
			} else {
				sb.WriteByte(char)
			}

		case STATE_DQ_JSON:
			if i == jsonEndIndex {
				// We reached the closing quote of the JSON string
				state = STATE_NORMAL
				sb.WriteByte(char)
			} else if char == '"' {
				// Inner quote - escape it
				sb.WriteString("\\\"")
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else if char == '\n' {
				sb.WriteString("\\n")
			} else {
				sb.WriteByte(char)
			}

		case STATE_TSQ:
			if char == '\'' && i+2 < n && code[i+1] == '\'' && code[i+2] == '\'' {
				state = STATE_NORMAL
				sb.WriteString("'''")
				i += 2
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else {
				sb.WriteByte(char)
			}

		case STATE_TDQ:
			if char == '"' && i+2 < n && code[i+1] == '"' && code[i+2] == '"' {
				state = STATE_NORMAL
				sb.WriteString("\"\"\"")
				i += 2
			} else if char == '\\' {
				sb.WriteByte(char)
				if i+1 < n {
					i++
					sb.WriteByte(code[i])
				}
			} else {
				sb.WriteByte(char)
			}
		}
	}

	return sb.String()
}

// findJSONStringEnd attempts to find the end of a string that starts with "{"
// It returns the index of the closing quote if it successfully parses the structure
// matching the braces and ensuring quotes inside are not Python string closers.
func findJSONStringEnd(code string, start int) int {
	n := len(code)
	depth := 1 // We start after '{'
	inString := false

	for i := start; i < n; i++ {
		char := code[i]

		if inString {
			if char == '\\' {
				i++
				continue
			}
			if char == '"' {
				// We are inside a JSON key or value string.
				// This quote could be the end of that key/value.
				// Check if the next character looks like a structural JSON character
				// (colon, comma, closing brace, etc.)
				if i+1 < n {
					next := code[i+1]
					if isJSONStructural(next) {
						inString = false
					}
					// If not structural, we assume it's part of the content (e.g. unescaped quote in bad JSON)
					// BUT wait, if we are parsing bad JSON s="{"k": "v"}", we WANT to detect "v" as a string.
					// "v" end quote is followed by }. } IS structural. So inString=false.
					// "k" end quote is followed by :. : IS structural. So inString=false.
					// "val"ue". "val" end quote is followed by u. u is NOT structural. So inString remains true?
					// If inString remains true, we consume "ue".
					// Then we hit next ".
					// This effectively parses through "bad" quotes inside the JSON string value if they are not followed by structure.
				} else {
					return -1 // EOF
				}
			}
		} else {
			// We are not in a JSON key/value string (we are expecting key, :, value, comma, or })
			if char == '"' {
				// This quote is either:
				// 1. The start of a JSON key/value string
				// 2. The closing quote of the Python string s="..."

				// Check if it looks like a Python string closer
				if i+1 < n {
					next := code[i+1]
					if isPythonCloserFollower(next) {
						// It looks like a real closer (e.g. s="{" + "}")
						// So this is NOT a JSON string we should auto-escape.
						return -1
					}
				}
				// Otherwise, treat as start of JSON string
				inString = true
			} else if char == '{' {
				depth++
			} else if char == '}' {
				depth--
				if depth == 0 {
					// We found the matching closing brace for the initial '{'
					// Now check if the NEXT character is the closing quote
					if i+1 < n && code[i+1] == '"' {
						return i + 1 // Index of the closing quote
					}
					// If not followed by ", then s="...}"something...
					// This implies s="..." didn't end here?
					// But we only track depth relative to start.
					// If depth hits 0, we expect string to end.
					// If s="{" + "}", depth hits 0 at first }.
					// Next char is ". Correct.

					// Wait, s="{" + "}".
					// " (end first string). isPythonCloserFollower(' ') -> True. Returns -1.
					// So we never reach here for s="{" + "}".

					// What about s="{}}".
					// depth 1 -> }. depth 0.
					// Next is }. Not ".
					// So return -1.
					return -1
				}
			}
		}
	}
	return -1
}

func isJSONStructural(char byte) bool {
	// Chars that can follow a closing quote of a JSON key/value
	return char == ':' || char == ',' || char == '}' || char == ']' || char == ' ' || char == '\t' || char == '\n' || char == '\r'
}

func isPythonCloserFollower(char byte) bool {
	// Chars that can follow a Python string literal
	// Whitespace
	if char == ' ' || char == '\t' || char == '\n' || char == '\r' {
		return true
	}
	// Operators and delimiters
	switch char {
	case ')', ']', ',', '.', ';', '#':
		return true
	case '+', '-', '*', '/', '%', '&', '|', '^', '=', '!', '<', '>', '?':
		return true
	}
	// Note: '}' is NOT included because s="...}" should typically not be followed by '}'
	// unless inside a dict like {"k": "v"}, but in that case findJSONStringEnd isn't called
	// because string doesn't start with '{'.
	// Even if it did {"k": "{"}, the } following the string is the dict closer,
	// so it IS a Python closer follower contextually.
	// But our heuristic assumes we are fixing a broken string literal s="...".
	// s="{"...}" } is invalid syntax.

	return false
}

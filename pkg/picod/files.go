package picod

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
	"k8s.io/klog/v2"
)

const (
	maxFileMode = 0777 // Maximum allowed file permission mode
)

// FileInfo defines file information response body
type FileInfo struct {
	Path     string    `json:"path"`
	Size     int64     `json:"size"`
	Mode     string    `json:"mode"`
	Modified time.Time `json:"modified"`
}

// UploadFileRequest defines JSON upload request body
type UploadFileRequest struct {
	Path    string `json:"path" binding:"required"`
	Content string `json:"content" binding:"required"` // Base64 encoded content
	Mode    string `json:"mode"`
}

// UploadFileHandler handles file upload requests
func (s *Server) UploadFileHandler(c *gin.Context) {
	requestStart := time.Now()
	contentType := c.ContentType()

	// Determine request type: multipart or JSON
	if strings.HasPrefix(contentType, "multipart/form-data") {
		s.handleMultipartUpload(c)
	} else {
		s.handleJSONBase64Upload(c)
	}

	klog.Infof("[UploadFileHandler] Request completed in %.3f seconds", time.Since(requestStart).Seconds())
}

func (s *Server) handleMultipartUpload(c *gin.Context) {
	path := c.PostForm("path")
	if path == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Missing 'path' field",
			"code":  http.StatusBadRequest,
		})
		return
	}

	fileHeader, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("Failed to get file: %v", err),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Ensure path safety
	safePath, err := s.sanitizePath(path)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Create directory
	dir := filepath.Dir(safePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to create directory: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Parse mode first
	modeStr := c.PostForm("mode")
	fileMode := parseFileMode(modeStr)

	// Open source file
	src, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to open uploaded file", "code": http.StatusInternalServerError})
		return
	}
	defer src.Close()

	// Create destination file with correct permissions
	dst, err := os.OpenFile(safePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, fileMode)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create destination file", "code": http.StatusInternalServerError})
		return
	}
	defer dst.Close()

	// Copy content
	if _, err := io.Copy(dst, src); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to save file content", "code": http.StatusInternalServerError})
		return
	}

	stat, err := os.Stat(safePath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to get file info: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	relPath, err := filepath.Rel(s.workspaceDir, safePath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to get relative path: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, FileInfo{
		Path:     relPath,
		Size:     stat.Size(),
		Mode:     stat.Mode().String(),
		Modified: stat.ModTime(),
	})
}

func (s *Server) handleJSONBase64Upload(c *gin.Context) {
	var req UploadFileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Ensure path safety
	safePath, err := s.sanitizePath(req.Path)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Decode Base64 content
	decodedContent, err := base64.StdEncoding.DecodeString(req.Content)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("Invalid base64 content: %v", err),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Create directory
	dir := filepath.Dir(safePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to create directory: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Parse and validate file permissions
	fileMode := parseFileMode(req.Mode)

	// Write file with the specified permissions
	err = os.WriteFile(safePath, decodedContent, fileMode)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to write file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	stat, err := os.Stat(safePath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to get file info: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	relPath, err := filepath.Rel(s.workspaceDir, safePath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to get relative path: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, FileInfo{
		Path:     relPath,
		Size:     stat.Size(),
		Mode:     stat.Mode().String(),
		Modified: stat.ModTime(),
	})
}

// DownloadFileHandler handles file download requests
func (s *Server) DownloadFileHandler(c *gin.Context) {
	requestStart := time.Now()
	path := c.Param("path")
	if path == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Missing file path",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Remove leading /
	path = strings.TrimPrefix(path, "/")

	// Gin automatically decodes URL-encoded path parameters, but let's ensure it's properly decoded
	// This handles cases where the path might be double-encoded or contain special characters
	decodedPath, err := url.QueryUnescape(path)
	if err != nil {
		// If decoding fails, use the original path (it might already be decoded)
		klog.V(4).Infof("Path decoding failed, using original: %v", err)
		decodedPath = path
	}

	// Ensure path safety
	safePath, err := s.sanitizePath(decodedPath)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	fileInfo, err := os.Stat(safePath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{
				"error": "File not found",
				"code":  http.StatusNotFound,
			})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to get file info: %v", err),
				"code":  http.StatusInternalServerError,
			})
		}
		return
	}

	if fileInfo.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Path is a directory, not a file",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Try to guess Content-Type based on file extension
	contentType := mime.TypeByExtension(filepath.Ext(safePath))
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	// Get the filename for Content-Disposition
	filename := filepath.Base(safePath)

	c.Header("Content-Description", "File Transfer")
	c.Header("Content-Transfer-Encoding", "binary")
	c.Header("Content-Disposition", encodeContentDisposition(filename))
	c.Header("Content-Type", contentType)
	c.File(safePath)

	klog.Infof("[DownloadFileHandler] Request completed in %.3f seconds, path: %s, size: %d bytes",
		time.Since(requestStart).Seconds(), decodedPath, fileInfo.Size())
}

// FileEntry defines a single file entry in the list response
type FileEntry struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
	Mode     string    `json:"mode"`
	IsDir    bool      `json:"is_dir"`
}

// ListFilesResponse defines file listing response body
type ListFilesResponse struct {
	Files []FileEntry `json:"files"`
}

// ListFilesHandler handles file listing requests
func (s *Server) ListFilesHandler(c *gin.Context) {
	requestStart := time.Now()
	path := c.Query("path")
	if path == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Missing 'path' query parameter",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Ensure path safety
	safePath, err := s.sanitizePath(path)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	entries, err := os.ReadDir(safePath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{
				"error": "Directory not found",
				"code":  http.StatusNotFound,
			})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to read directory: %v", err),
				"code":  http.StatusInternalServerError,
			})
		}
		return
	}

	var files []FileEntry
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			klog.Warningf("Failed to get info for entry '%s': %v", entry.Name(), err)
			continue // Skip files with errors
		}
		files = append(files, FileEntry{
			Name:     entry.Name(),
			Size:     info.Size(),
			Modified: info.ModTime(),
			Mode:     info.Mode().String(),
			IsDir:    entry.IsDir(),
		})
	}

	c.JSON(http.StatusOK, ListFilesResponse{
		Files: files,
	})

	klog.Infof("[ListFilesHandler] Request completed in %.3f seconds, path: %s, files_count: %d",
		time.Since(requestStart).Seconds(), path, len(files))
}

// parseFileMode parses file mode string
func parseFileMode(modeStr string) os.FileMode {
	if modeStr == "" {
		return 0644
	}
	mode, err := strconv.ParseUint(modeStr, 8, 32)
	if err != nil {
		klog.Warningf("Invalid file mode '%s': %v, using default 0644", modeStr, err)
		return 0644
	}
	if mode > maxFileMode {
		klog.Warningf("Invalid file mode '%s': exceeds 0777, using default 0644", modeStr)
		return 0644
	}
	return os.FileMode(mode)
}

// setWorkspace sets the global workspace directory
func (s *Server) setWorkspace(dir string) {
	absDir, err := filepath.Abs(dir)
	if err != nil {
		klog.Warningf("Failed to resolve absolute path for workspace '%s': %v", dir, err)
		s.workspaceDir = dir // Fallback to provided path
	} else {
		s.workspaceDir = absDir
	}
}

// encodeContentDisposition encodes the Content-Disposition header value with proper filename encoding
// It follows RFC 2231 for non-ASCII filenames and RFC 6266 recommendations
func encodeContentDisposition(filename string) string {
	// Check if filename contains non-ASCII characters
	needsEncoding := false
	for _, r := range filename {
		if r > unicode.MaxASCII {
			needsEncoding = true
			break
		}
	}

	if !needsEncoding {
		// Simple ASCII filename, use standard format with escaped quotes
		escapedFilename := strings.ReplaceAll(filename, "\\", "\\\\")
		escapedFilename = strings.ReplaceAll(escapedFilename, "\"", "\\\"")
		return fmt.Sprintf(`attachment; filename="%s"`, escapedFilename)
	}

	// Non-ASCII filename: provide both ASCII fallback and UTF-8 encoded version
	// RFC 2231 format: filename*=UTF-8''encoded_filename
	// Also provide a simple ASCII fallback for older clients
	asciiFilename := toASCII(filename)
	escapedASCII := strings.ReplaceAll(asciiFilename, "\\", "\\\\")
	escapedASCII = strings.ReplaceAll(escapedASCII, "\"", "\\\"")

	// URL-encode the UTF-8 filename (RFC 2231)
	encodedFilename := url.QueryEscape(filename)

	return fmt.Sprintf(`attachment; filename="%s"; filename*=UTF-8''%s`, escapedASCII, encodedFilename)
}

// toASCII converts a string to ASCII by removing or replacing non-ASCII characters
func toASCII(s string) string {
	var result strings.Builder
	for _, r := range s {
		if r <= unicode.MaxASCII {
			result.WriteRune(r)
		} else {
			result.WriteRune('_')
		}
	}
	return result.String()
}

// UploadDirectoryRequest defines directory upload request body
type UploadDirectoryRequest struct {
	BasePath string     `json:"base_path"` // Base directory path (optional)
	Files    []FileItem `json:"files" binding:"required,min=1"`
}

// FileItem defines a single file in directory upload
type FileItem struct {
	Path    string `json:"path" binding:"required"`
	Content string `json:"content" binding:"required"` // Base64 encoded
	Mode    string `json:"mode"`
}

// UploadDirectoryResponse defines directory upload response
type UploadDirectoryResponse struct {
	UploadedFiles []FileInfo `json:"uploaded_files"`
	TotalFiles    int        `json:"total_files"`
	TotalSize     int64      `json:"total_size"`
}

// UploadDirectoryHandler handles directory upload requests
func (s *Server) UploadDirectoryHandler(c *gin.Context) {
	requestStart := time.Now()
	var req UploadDirectoryRequest

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": fmt.Sprintf("Invalid request: %v", err),
			"code":  http.StatusBadRequest,
		})
		return
	}

	var uploadedFiles []FileInfo
	var totalSize int64

	// Process each file
	for _, fileItem := range req.Files {
		// Construct full path
		fullPath := fileItem.Path
		if req.BasePath != "" {
			fullPath = filepath.Join(req.BasePath, fileItem.Path)
		}

		// Ensure path safety
		safePath, err := s.sanitizePath(fullPath)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": fmt.Sprintf("Invalid path '%s': %v", fullPath, err),
				"code":  http.StatusBadRequest,
			})
			return
		}

		// Decode Base64 content
		decodedContent, err := base64.StdEncoding.DecodeString(fileItem.Content)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": fmt.Sprintf("Invalid base64 content for '%s': %v", fullPath, err),
				"code":  http.StatusBadRequest,
			})
			return
		}

		// Create directory
		dir := filepath.Dir(safePath)
		if err := os.MkdirAll(dir, 0755); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to create directory for '%s': %v", fullPath, err),
				"code":  http.StatusInternalServerError,
			})
			return
		}

		// Parse file permissions
		fileMode := parseFileMode(fileItem.Mode)

		// Write file
		if err := os.WriteFile(safePath, decodedContent, fileMode); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to write file '%s': %v", fullPath, err),
				"code":  http.StatusInternalServerError,
			})
			return
		}

		// Get file info
		stat, err := os.Stat(safePath)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to get file info for '%s': %v", fullPath, err),
				"code":  http.StatusInternalServerError,
			})
			return
		}

		relPath, err := filepath.Rel(s.workspaceDir, safePath)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to get relative path for '%s': %v", fullPath, err),
				"code":  http.StatusInternalServerError,
			})
			return
		}

		uploadedFiles = append(uploadedFiles, FileInfo{
			Path:     relPath,
			Size:     stat.Size(),
			Mode:     stat.Mode().String(),
			Modified: stat.ModTime(),
		})
		totalSize += stat.Size()
	}

	c.JSON(http.StatusOK, UploadDirectoryResponse{
		UploadedFiles: uploadedFiles,
		TotalFiles:    len(uploadedFiles),
		TotalSize:     totalSize,
	})

	klog.Infof("[UploadDirectoryHandler] Uploaded %d files, total size: %d bytes, completed in %.3f seconds",
		len(uploadedFiles), totalSize, time.Since(requestStart).Seconds())
}

// DownloadDirectoryHandler handles directory download requests
func (s *Server) DownloadDirectoryHandler(c *gin.Context) {
	requestStart := time.Now()
	path := c.Param("path")
	if path == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Missing directory path",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Remove leading /
	path = strings.TrimPrefix(path, "/")

	// Decode URL-encoded path
	decodedPath, err := url.QueryUnescape(path)
	if err != nil {
		klog.V(4).Infof("Path decoding failed, using original: %v", err)
		decodedPath = path
	}

	// Ensure path safety
	safePath, err := s.sanitizePath(decodedPath)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": err.Error(),
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Check if directory exists
	fileInfo, err := os.Stat(safePath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{
				"error": "Directory not found",
				"code":  http.StatusNotFound,
			})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to get directory info: %v", err),
				"code":  http.StatusInternalServerError,
			})
		}
		return
	}

	if !fileInfo.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Path is not a directory",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Get format from query parameter (default: tar.gz)
	format := c.DefaultQuery("format", "tar.gz")
	if format != "tar.gz" && format != "zip" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "Invalid format, must be 'tar.gz' or 'zip'",
			"code":  http.StatusBadRequest,
		})
		return
	}

	// Create temporary file for archive
	tmpFile, err := os.CreateTemp("", fmt.Sprintf("picod-download-*.%s", format))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to create temporary file: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	// Create archive
	if format == "tar.gz" {
		if err := s.createTarGz(safePath, tmpFile); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to create tar.gz: %v", err),
				"code":  http.StatusInternalServerError,
			})
			return
		}
	} else {
		if err := s.createZip(safePath, tmpFile); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"error": fmt.Sprintf("Failed to create zip: %v", err),
				"code":  http.StatusInternalServerError,
			})
			return
		}
	}

	// Get archive size
	tmpFile.Sync()
	archiveStat, err := tmpFile.Stat()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": fmt.Sprintf("Failed to get archive info: %v", err),
			"code":  http.StatusInternalServerError,
		})
		return
	}

	// Prepare filename for download
	dirName := filepath.Base(safePath)
	filename := fmt.Sprintf("%s.%s", dirName, format)

	// Set response headers
	c.Header("Content-Description", "File Transfer")
	c.Header("Content-Transfer-Encoding", "binary")
	c.Header("Content-Disposition", encodeContentDisposition(filename))

	if format == "tar.gz" {
		c.Header("Content-Type", "application/gzip")
	} else {
		c.Header("Content-Type", "application/zip")
	}

	// Send file
	c.File(tmpFile.Name())

	klog.Infof("[DownloadDirectoryHandler] Downloaded directory '%s' as %s, size: %d bytes, completed in %.3f seconds",
		decodedPath, format, archiveStat.Size(), time.Since(requestStart).Seconds())
}

// sanitizePath ensures path is within allowed scope, preventing directory traversal attacks
func (s *Server) sanitizePath(p string) (string, error) {
	if s.workspaceDir == "" {
		return "", fmt.Errorf("workspace directory not initialized")
	}

	resolvedWorkspace, err := filepath.EvalSymlinks(s.workspaceDir)
	if err != nil {
		if abs, err2 := filepath.Abs(s.workspaceDir); err2 == nil {
			resolvedWorkspace = abs
		} else {
			resolvedWorkspace = filepath.Clean(s.workspaceDir)
		}
	}
	// Ensure base workspace path is clean and absolute for reliable comparison with filepath.Rel
	resolvedWorkspace = filepath.Clean(resolvedWorkspace)

	// Clean the input path; if it's absolute, treat it as relative to the workspace root.
	cleanPath := filepath.Clean(p)
	if filepath.IsAbs(cleanPath) {
		cleanPath = strings.TrimPrefix(cleanPath, string(os.PathSeparator))
	}

	// Construct the full absolute path candidate within the workspace.
	// filepath.Join handles cases like "a/../b", but we also need to filepath.Clean it afterwards
	// to normalize any ".." components that might be introduced by `Join` if `cleanPath` itself
	// contained them.
	fullPathCandidate := filepath.Join(resolvedWorkspace, cleanPath)
	fullPathCandidate = filepath.Clean(fullPathCandidate)

	// Robustly check if fullPathCandidate is truly within resolvedWorkspace using filepath.Rel.
	// filepath.Rel returns a path relative to base, or an error if target cannot be made relative to base.
	relPath, relErr := filepath.Rel(resolvedWorkspace, fullPathCandidate)
	if relErr != nil {
		return "", fmt.Errorf("access denied: path '%s' escapes workspace jail (rel error: %w)", p, relErr)
	}
	// Also explicitly check for ".." at the start of the relative path, which indicates traversal outside the workspace,
	// or if the path is ".." itself, both implying an escape.
	if strings.HasPrefix(relPath, ".."+string(os.PathSeparator)) || relPath == ".." {
		return "", fmt.Errorf("access denied: path '%s' escapes workspace jail (relative path traversal: %s)", p, relPath)
	}

	// At this point, fullPathCandidate is proven to be within resolvedWorkspace or is resolvedWorkspace itself.
	// Now, attempt to resolve symlinks for the final path. If this resolution leads outside the workspace,
	// it indicates a symlink attack.
	resolvedFinalPath, err := filepath.EvalSymlinks(fullPathCandidate)
	if err == nil {
		// If resolvedFinalPath exists and is a symlink, re-check it against the workspace
		finalRelPath, finalRelErr := filepath.Rel(resolvedWorkspace, resolvedFinalPath)
		if finalRelErr != nil || strings.HasPrefix(finalRelPath, ".."+string(os.PathSeparator)) || finalRelPath == ".." {
			return "", fmt.Errorf("access denied: resolved path '%s' (from '%s') escapes workspace jail via symlink", resolvedFinalPath, p)
		}
		return resolvedFinalPath, nil
	}

	// If the path does not exist (e.g., a new file/directory is being created),
	// we have already verified that fullPathCandidate (the intended location) is safe.
	// Return its absolute, cleaned form.
	return fullPathCandidate, nil
}

// createTarGz creates a tar.gz archive of the given directory
func (s *Server) createTarGz(srcDir string, dst *os.File) error {
	gzWriter := gzip.NewWriter(dst)
	defer gzWriter.Close()

	tarWriter := tar.NewWriter(gzWriter)
	defer tarWriter.Close()

	// Get the base name for relative path calculation
	baseDir := filepath.Dir(srcDir)

	// Walk the directory tree
	return filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Create tar header
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return fmt.Errorf("failed to create tar header for '%s': %w", path, err)
		}

		// Set relative path in archive
		relPath, err := filepath.Rel(baseDir, path)
		if err != nil {
			return fmt.Errorf("failed to get relative path for '%s': %w", path, err)
		}
		header.Name = filepath.ToSlash(relPath)

		// Write header
		if err := tarWriter.WriteHeader(header); err != nil {
			return fmt.Errorf("failed to write tar header for '%s': %w", path, err)
		}

		// Write file content (skip directories)
		if !info.IsDir() {
			file, err := os.Open(path)
			if err != nil {
				return fmt.Errorf("failed to open file '%s': %w", path, err)
			}
			defer file.Close()

			if _, err := io.Copy(tarWriter, file); err != nil {
				return fmt.Errorf("failed to write file content for '%s': %w", path, err)
			}
		}

		return nil
	})
}

// createZip creates a zip archive of the given directory
func (s *Server) createZip(srcDir string, dst *os.File) error {
	zipWriter := zip.NewWriter(dst)
	defer zipWriter.Close()

	// Get the base name for relative path calculation
	baseDir := filepath.Dir(srcDir)

	// Walk the directory tree
	return filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip directories (zip will create them automatically)
		if info.IsDir() {
			return nil
		}

		// Get relative path
		relPath, err := filepath.Rel(baseDir, path)
		if err != nil {
			return fmt.Errorf("failed to get relative path for '%s': %w", path, err)
		}

		// Create zip file header
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return fmt.Errorf("failed to create zip header for '%s': %w", path, err)
		}
		header.Name = filepath.ToSlash(relPath)
		header.Method = zip.Deflate

		// Create file writer
		writer, err := zipWriter.CreateHeader(header)
		if err != nil {
			return fmt.Errorf("failed to create zip writer for '%s': %w", path, err)
		}

		// Write file content
		file, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("failed to open file '%s': %w", path, err)
		}
		defer file.Close()

		if _, err := io.Copy(writer, file); err != nil {
			return fmt.Errorf("failed to write file content for '%s': %w", path, err)
		}

		return nil
	})
}

package main

import (
	"flag"
	"os"
	"strconv"

	"k8s.io/klog/v2"

	"github.com/volcano-sh/agentcube/pkg/picod"
)

func main() {
	port := flag.Int("port", 8080, "Port for the PicoD server to listen on")
	bootstrapKeyFile := flag.String("bootstrap-key", "/etc/picod/public-key.pem", "Path to the bootstrap public key file")
	workspace := flag.String("workspace", "", "Root directory for file operations (default: current working directory)")
	maxBodySize := flag.Int64("max-body-size", 64<<20, "Maximum request body size in bytes (default: 64MB)")

	// Initialize klog flags
	klog.InitFlags(nil)
	flag.Parse()

	// Get auth mode from environment variable, default to "dynamic"
	authMode := os.Getenv("PICOD_AUTH_MODE")
	if authMode == "" {
		authMode = "dynamic"
	}

	// Read bootstrap key from file (required for dynamic mode, optional for static mode)
	var bootstrapKey []byte
	if data, err := os.ReadFile(*bootstrapKeyFile); err == nil {
		bootstrapKey = data
	} else if authMode == picod.AuthModeDynamic {
		// Bootstrap key is required for dynamic mode
		klog.Fatalf("Failed to read bootstrap key from %s: %v", *bootstrapKeyFile, err)
	} else {
		// In static mode, bootstrap key is optional
		klog.Infof("Bootstrap key not found at %s (optional in static mode)", *bootstrapKeyFile)
	}

	// Get port from environment variable, default to flag value
	portVal := *port
	if envPort := os.Getenv("PICOD_PORT"); envPort != "" {
		if p, err := strconv.Atoi(envPort); err == nil {
			portVal = p
		} else {
			klog.Warningf("Invalid PICOD_PORT value '%s', using flag value %d", envPort, *port)
		}
	}

	// Get workspace from environment variable, default to flag value
	workspaceVal := *workspace
	if envWorkspace := os.Getenv("PICOD_WORKSPACE"); envWorkspace != "" {
		workspaceVal = envWorkspace
	}

	// Get max body size from environment variable, default to flag value
	maxBodySizeVal := *maxBodySize
	if envMaxBodySize := os.Getenv("PICOD_MAX_BODY_SIZE"); envMaxBodySize != "" {
		if m, err := strconv.ParseInt(envMaxBodySize, 10, 64); err == nil {
			maxBodySizeVal = m
		} else {
			klog.Warningf("Invalid PICOD_MAX_BODY_SIZE value '%s', using flag value %d", envMaxBodySize, *maxBodySize)
		}
	}

	config := picod.Config{
		Port:         portVal,
		BootstrapKey: bootstrapKey,
		Workspace:    workspaceVal,
		AuthMode:     authMode,
		MaxBodySize:  maxBodySizeVal,
	}

	// Create and start server
	server := picod.NewServer(config)

	if err := server.Run(); err != nil {
		klog.Fatalf("Failed to start server: %v", err)
	}
}

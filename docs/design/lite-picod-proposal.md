# Lite Picod Proposal

## Workflow

```mermaid
sequenceDiagram
    participant Client as SDK Client
    participant Router as Router
    participant WorkloadMgr as Workload Manager
    box Codeinterpreter
    participant PicoD as PicoD Daemon
    participant Kernal as Jupyter Kneral
    end

    Note over Router, Kernal: Bootstrap Phase (Sandbox Creation)
    Router->>Router: Generate Bootstrap Key Pair
    Router->>Router: Save Public Key to Secret
    PicoD->>PicoD: Mount Public Key
    PicoD->>Kernal: Start Jupyter Kneral

    
    Note over Client, Kernal: Initialization Phase (Sandbox Allocation)
    Client->>WorkloadMgr: POST /v1/sandboxes (create sandbox request)
    WorkloadMgr->>WorkloadMgr: Allocate Sandbox to Client
    WorkloadMgr-->>Client: Return Sandbox Info (session_id, endpoints)
    
    Note over Client, Kernal: Operation Phase (Authenticated Requests)
    Client->>Router: POST /api/run_python
    Note right of Router: JWT Claims:<br/>- iat, exp
    Router->>PicoD: Proxy /api/run_python (signed by Private Key)
    PicoD->>PicoD: Verify JWT with Stored Public Key
    PicoD->>Kernal: Run python code 
    Kernal-->>PicoD: Execution Result
    PicoD-->>Client: Execution Result
```

## Codeinterpreter Modification

1. **Mount public key instead of injection**
   1. Add options `disable_init`
   2. Verify operation request with mounted public key
2. **Run python code with Jupyter Kernal**
   1. Picod add a interface named /api/run_python
   2. Picod start a Jupyter Kernal at codeinterpreter start
   3. Run python code with jupyter kernal and reset kernel after each exectuation

## Need to confirm

1. **Where to sign JWT with private key**: router(ERS gateway) or SDK?
2. **What in JWT claims**: agent indentity?


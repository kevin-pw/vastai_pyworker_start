#!/bin/bash

set -e -o pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

MODEL_LOG="$WORKSPACE_DIR/model.log"
OLLAMA_DIR="/bin"

SERVER_DIR="$WORKSPACE_DIR/vast-pyworker"
ENV_PATH="$WORKSPACE_DIR/worker-env"
DEBUG_LOG="$WORKSPACE_DIR/debug.log"
PYWORKER_LOG="$WORKSPACE_DIR/pyworker.log"

REPORT_ADDR="${REPORT_ADDR:-https://run.vast.ai}"
SIGNING_KEY_ADDR="${SIGNING_KEY_ADDR:-https://run.vast.ai/pubkey/}"
USE_SSL="${USE_SSL:-true}"
WORKER_PORT="${WORKER_PORT:-3000}"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# make all output go to $DEBUG_LOG and stdout without having to add `... | tee -a $DEBUG_LOG` to every command
exec &> >(tee -a "$DEBUG_LOG")

function echo_var(){
    echo "$1: ${!1}"
}

# Hardcoding $BACKEND because this script is only for ollamaimgembed
BACKEND="ollamaimgembed"

[ -z "$BACKEND" ] && echo "BACKEND must be set!" && exit 1
[ -z "$MODEL_LOG" ] && echo "MODEL_LOG must be set!" && exit 1
[ -z "$GIT_DEPLOY_KEY" ] && echo "GIT_DEPLOY_KEY must be set so that we can download the vastai pyworker from our private repo!" && exit 1

echo "start_server_ollamaimgembed.sh"
date

echo_var BACKEND
echo_var REPORT_ADDR
echo_var SIGNING_KEY_ADDR
echo_var WORKER_PORT
echo_var WORKSPACE_DIR
echo_var SERVER_DIR
echo_var ENV_PATH
echo_var DEBUG_LOG
echo_var PYWORKER_LOG
echo_var MODEL_LOG
echo_var OLLAMA_DIR

env | grep _ >> /etc/environment;


echo "Starting ollama server"
# cd "$OLLAMA_DIR"
(${OLLAMA_DIR}/ollama serve 2>&1 >> "$MODEL_LOG") &
echo "Ollama server started. Logs will appear in $MODEL_LOG"

# Wait for the server to be ready
echo "Waiting for the Ollama server to start..."
MAX_RETRIES=30
RETRY_INTERVAL=1
SERVER_URL="http://127.0.0.1:11434"
for ((i=1; i<=MAX_RETRIES; i++)); do
    if curl -s "$SERVER_URL" >/dev/null 2>&1; then
        echo "Ollama server is up!"
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: Ollama server failed to start after $((MAX_RETRIES * RETRY_INTERVAL)) seconds."
        exit 1
    fi
    echo "Ollama server not yet responding after retry number: $i"
    sleep $RETRY_INTERVAL
done

echo "Pulling ollama model"
#cd "$OLLAMA_DIR"
#./ollama pull llama3.2-vision:11b 2>&1 >> "$MODEL_LOG"
(${OLLAMA_DIR}/ollama pull llama3.2-vision:11b 2>&1 >> "$MODEL_LOG") &
echo "Pulling ollama model complete"

# Setup the vastai pyworker repo on local and activate the environment
if [ ! -d "$ENV_PATH" ]
then
    # Setup github deploy key from env to access private repo
    mkdir -p ~/.ssh
    # Write the base64-encoded key to ~/.ssh/id_rsa
    echo "$GIT_DEPLOY_KEY" | base64 -d > ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa

    # Add github.com to known_hosts to avoid host-check prompts
    ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts 2>/dev/null || true

    # Optional: set GIT_SSH_COMMAND to force usage of our deploy key
    export GIT_SSH_COMMAND='ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no'

    # install virtual environment
    apt install -y python3.10-venv
    echo "setting up venv"
    echo "DEBUG: script has been updated successfully"
    git clone git@github.com:kevin-pw/vastai_pyworker.git "$SERVER_DIR" \
    || { 
        echo "ERROR: git clone failed! Check deploy key or repo URL." >&2
        exit 1
    }

    python3 -m venv "$WORKSPACE_DIR/worker-env"
    source "$WORKSPACE_DIR/worker-env/bin/activate"

    pip install -r vast-pyworker/requirements.txt

    touch ~/.no_auto_tmux
else
    source "$WORKSPACE_DIR/worker-env/bin/activate"
    echo "environment activated"
    echo "venv: $VIRTUAL_ENV"
fi

[ ! -d "$SERVER_DIR/workers/$BACKEND" ] && echo "$BACKEND not supported!" && exit 1

if [ "$USE_SSL" = true ]; then

    cat << EOF > /etc/openssl-san.cnf
    [req]
    default_bits       = 2048
    distinguished_name = req_distinguished_name
    req_extensions     = v3_req

    [req_distinguished_name]
    countryName         = US
    stateOrProvinceName = CA
    organizationName    = Vast.ai Inc.
    commonName          = vast.ai

    [v3_req]
    basicConstraints = CA:FALSE
    keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
    subjectAltName   = @alt_names

    [alt_names]
    IP.1   = 0.0.0.0
EOF

openssl req -newkey rsa:2048 -subj "/C=US/ST=CA/CN=pyworker.vast.ai/" \
    -nodes \
    -sha256 \
    -keyout /etc/instance.key \
    -out /etc/instance.csr \
    -config /etc/openssl-san.cnf

curl --header 'Content-Type: application/octet-stream' \
    --data-binary @//etc/instance.csr \
    -X \
    POST "https://console.vast.ai/api/v0/sign_cert/?instance_id=$CONTAINER_ID" > /etc/instance.crt;
fi

export REPORT_ADDR SIGNING_KEY_ADDR WORKER_PORT USE_SSL MODEL_LOG

# if instance is rebooted, we want to clear out the log file so pyworker doesn't read lines
# from the run prior to reboot. past logs are saved in $MODEL_LOG.old for debugging only
[ -e "$MODEL_LOG" ] && cat "$MODEL_LOG" >> "$MODEL_LOG.old" && : > "$MODEL_LOG"

echo "launching PyWorker server"
cd "$SERVER_DIR"
(python3 -m "workers.$BACKEND.server" |& tee -a "$PYWORKER_LOG") &
echo "launching PyWorker server done"

# Deactivate the virtual environment
# deactivate
# echo "Virtual environment deactivated."

# echo "Starting ollama server"
# cd "$OLLAMA_DIR"
# (./ollama serve 2>&1 >> "$MODEL_LOG") &
# echo "Ollama server started. Logs will appear in $MODEL_LOG"

# # Wait for the server to be ready
# echo "Waiting for the Ollama server to start..."
# MAX_RETRIES=30
# RETRY_INTERVAL=1
# SERVER_URL="http://127.0.0.1:11434"
# for ((i=1; i<=MAX_RETRIES; i++)); do
#     if curl -s "$SERVER_URL" >/dev/null 2>&1; then
#         echo "Ollama server is up!"
#         break
#     fi
#     if [ $i -eq $MAX_RETRIES ]; then
#         echo "ERROR: Ollama server failed to start after $((MAX_RETRIES * RETRY_INTERVAL)) seconds."
#         exit 1
#     fi
#     echo "Ollama server not yet responding after retry number: $i"
#     sleep $RETRY_INTERVAL
# done

# echo "Pulling ollama model"
# cd "$OLLAMA_DIR"
# ./ollama pull llama3.2-vision:11b 2>&1 >> "$MODEL_LOG"
# echo "Pulling ollama model complete"
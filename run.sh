#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]

Required:
  --cluster <torch|greene>
  --ssh-user <user>
  --scratch-dir <path>
  --log-dir <path>
  --overlay-src <path>
  --docker-url <url>
  --entrypoint-repo <repo>
  --entrypoint-commit <sha>
  --entrypoint-path <path>

Optional:
  --image <name>              (default: derived from docker-url)
  --service-name <name>       (default: <image>-<ssh-user>)
  --account <account>
  --build-time <HH:MM:SS>     (default: 00:45:00)
  --build-cpus <n>            (default: 8)
  --build-mem <mem>           (default: 16G)
  --run-time <HH:MM:SS>       (default: 06:00:00)
  --run-cpus <n>              (default: 4)
  --run-mem <mem>             (default: 24G)
  --binds <paths>             (default: none)
  --ssh-bind <path>           (default: /home/<ssh-user>/.ssh)
  --consul-ssh-user <user>    (default: ssh-user)
  --proxyjump <host>          (default: cluster)
  --local-forwards <forwards> (default: none)
  --consul-port <port>        (default: 2001)
  --consul-endpoint <url>     (default: http://10.18.124.118:8500)
  --use-gpu                   (flag)
  --force-rebuild             (flag)
  --exclusive                 (flag)
  --fakeroot                  (flag)
  --no-consul                 (flag, skip consul registration)

EOF
    exit 1
}

# Defaults for optional params
BUILD_TIME="00:45:00"
BUILD_CPUS="8"
BUILD_MEM="16G"
RUN_TIME="06:00:00"
RUN_CPUS="4"
RUN_MEM="24G"
BINDS=""
USE_GPU="false"
FORCE_REBUILD="false"
EXCLUSIVE="false"
FAKEROOT="false"
NO_CONSUL="false"
CONSUL_PORT="2001"
LOCAL_FORWARDS=""
ACCOUNT=""
IMAGE=""
SERVICE_NAME=""
SSH_BIND=""
CONSUL_SSH_USER=""
PROXYJUMP=""
CONSUL_ENDPOINT="http://10.18.124.118:8500"

# Required params (unset)
CLUSTER=""
SSH_USER=""
SCRATCH_DIR=""
LOG_DIR=""
OVERLAY_SRC=""
DOCKER_URL=""
ENTRYPOINT_REPO=""
ENTRYPOINT_COMMIT=""
ENTRYPOINT_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --scratch-dir) SCRATCH_DIR="$2"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --overlay-src) OVERLAY_SRC="$2"; shift 2 ;;
        --docker-url) DOCKER_URL="$2"; shift 2 ;;
        --entrypoint-repo) ENTRYPOINT_REPO="$2"; shift 2 ;;
        --entrypoint-commit) ENTRYPOINT_COMMIT="$2"; shift 2 ;;
        --entrypoint-path) ENTRYPOINT_PATH="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --account) ACCOUNT="$2"; shift 2 ;;
        --build-time) BUILD_TIME="$2"; shift 2 ;;
        --build-cpus) BUILD_CPUS="$2"; shift 2 ;;
        --build-mem) BUILD_MEM="$2"; shift 2 ;;
        --run-time) RUN_TIME="$2"; shift 2 ;;
        --run-cpus) RUN_CPUS="$2"; shift 2 ;;
        --run-mem) RUN_MEM="$2"; shift 2 ;;
        --binds) BINDS="$2"; shift 2 ;;
        --ssh-bind) SSH_BIND="$2"; shift 2 ;;
        --consul-ssh-user) CONSUL_SSH_USER="$2"; shift 2 ;;
        --proxyjump) PROXYJUMP="$2"; shift 2 ;;
        --local-forwards) LOCAL_FORWARDS="$2"; shift 2 ;;
        --consul-port) CONSUL_PORT="$2"; shift 2 ;;
        --consul-endpoint) CONSUL_ENDPOINT="$2"; shift 2 ;;
        --use-gpu) USE_GPU="true"; shift ;;
        --force-rebuild) FORCE_REBUILD="true"; shift ;;
        --exclusive) EXCLUSIVE="true"; shift ;;
        --fakeroot) FAKEROOT="true"; shift ;;
        --no-consul) NO_CONSUL="true"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required
for var in CLUSTER SSH_USER SCRATCH_DIR LOG_DIR OVERLAY_SRC DOCKER_URL ENTRYPOINT_REPO ENTRYPOINT_COMMIT ENTRYPOINT_PATH; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --$(echo ${var} | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
        usage
    fi
done

# Derive defaults
[[ -z "$IMAGE" ]] && IMAGE=$(basename "$DOCKER_URL" | tr ':' '-')
[[ -z "$SERVICE_NAME" ]] && SERVICE_NAME="${IMAGE}-${SSH_USER}"
[[ -z "$SSH_BIND" ]] && SSH_BIND="/home/${SSH_USER}/.ssh"
[[ -z "$CONSUL_SSH_USER" ]] && CONSUL_SSH_USER="$SSH_USER"
[[ -z "$PROXYJUMP" ]] && PROXYJUMP="$CLUSTER"

SIF_PATH="${SCRATCH_DIR}/images/${IMAGE}.sif"
OVERLAY_PATH="${SCRATCH_DIR}/${IMAGE}.ext3"
TMP_DIR="${SCRATCH_DIR}/tmp_${IMAGE}"

ACCOUNT_DIRECTIVE=""
[[ -n "$ACCOUNT" ]] && ACCOUNT_DIRECTIVE="#SBATCH --account=${ACCOUNT}"

# ===== MAIN =====
echo "[1/6] Ensuring directories exist..."
ssh "$CLUSTER" "mkdir -p ${LOG_DIR} ${TMP_DIR} ${SCRATCH_DIR}/images"

echo "[2/6] Cancelling existing jobs..."
ssh "$CLUSTER" bash -s <<EOF
for jobname in "build_${IMAGE}" "run_${IMAGE}"; do
    active_jobs=\$(squeue -u ${SSH_USER} -n \$jobname -h -o "%i")
    if [ -n "\$active_jobs" ]; then
        echo "Cancelling \$jobname: \$active_jobs"
        for jobid in \$active_jobs; do scancel \$jobid; done
    fi
done
EOF

echo "[3/6] Checking if build is needed..."
BUILD_JOB_ID=""
IMAGE_EXISTS=$(ssh "$CLUSTER" "[ -f ${SIF_PATH} ] && echo exists || echo missing")

if [[ "$FORCE_REBUILD" == "true" || "$IMAGE_EXISTS" == "missing" ]]; then
    echo "    Submitting build job..."
    BUILD_OUT=$(ssh "$CLUSTER" bash -s <<EOF
sbatch <<SLURM
#!/bin/bash
#SBATCH --job-name=build_${IMAGE}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${BUILD_CPUS}
#SBATCH --mem=${BUILD_MEM}
#SBATCH --time=${BUILD_TIME}
#SBATCH --output=${LOG_DIR}/build-${IMAGE}-%j.log
#SBATCH --error=${LOG_DIR}/build-${IMAGE}-%j.err
${ACCOUNT_DIRECTIVE}

mkdir -p ${SCRATCH_DIR}/images
cp -rp ${OVERLAY_SRC} ${OVERLAY_PATH}.gz
gunzip -f ${OVERLAY_PATH}.gz
singularity build --force ${SIF_PATH} ${DOCKER_URL}
SLURM
EOF
)
    BUILD_JOB_ID=$(echo "$BUILD_OUT" | grep -oP 'Submitted batch job \K\d+' || true)
    echo "    Build job ID: ${BUILD_JOB_ID:-none}"
else
    echo "    Image exists, skipping build."
fi

echo "[4/6] Submitting run job..."
SLURM_DEPENDENCY=""
[[ -n "$BUILD_JOB_ID" ]] && SLURM_DEPENDENCY="#SBATCH --dependency=afterok:${BUILD_JOB_ID}"

GPU_SLURM=""
GPU_SINGULARITY=""
if [[ "$USE_GPU" == "true" ]]; then
    GPU_SLURM="#SBATCH --gres=gpu:1"
    GPU_SINGULARITY="--nv"
fi

SBATCH_EXCLUSIVE=""
[[ "$EXCLUSIVE" == "true" ]] && SBATCH_EXCLUSIVE="#SBATCH --exclusive"

FAKEROOT_SINGULARITY=""
[[ "$FAKEROOT" == "true" ]] && FAKEROOT_SINGULARITY="--fakeroot"

MANDATORY_BINDS="${SSH_BIND},${TMP_DIR}:/tmp"
FULL_BINDS="${MANDATORY_BINDS}"
[[ -n "$BINDS" ]] && FULL_BINDS="${MANDATORY_BINDS},${BINDS}"

SCRIPT_URL="https://raw.githubusercontent.com/${ENTRYPOINT_REPO}/${ENTRYPOINT_COMMIT}/${ENTRYPOINT_PATH}"

RUN_OUT=$(ssh "$CLUSTER" bash -s <<EOF
sbatch <<SLURM
#!/bin/bash
${SBATCH_EXCLUSIVE}
#SBATCH --job-name=run_${IMAGE}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=${RUN_MEM}
#SBATCH --time=${RUN_TIME}
#SBATCH --cpus-per-task=${RUN_CPUS}
#SBATCH --output=${LOG_DIR}/run-${IMAGE}-%j.log
#SBATCH --error=${LOG_DIR}/run-${IMAGE}-%j.err
${GPU_SLURM}
${SLURM_DEPENDENCY}
${ACCOUNT_DIRECTIVE}

set -euo pipefail
ENTRYPOINT_FILE=\\\$(mktemp)
curl -fsSL ${SCRIPT_URL} -o \\\$ENTRYPOINT_FILE
exec 3<"\\\$ENTRYPOINT_FILE"
rm "\\\$ENTRYPOINT_FILE"

singularity exec ${GPU_SINGULARITY} ${FAKEROOT_SINGULARITY} \\
  --containall --no-home --cleanenv \\
  --overlay ${OVERLAY_PATH}:rw \\
  --bind ${FULL_BINDS} \\
  ${SIF_PATH} \\
  bash <&3

exec 3<&-
SLURM
EOF
)

RUN_JOB_ID=$(echo "$RUN_OUT" | grep -oP 'Submitted batch job \K\d+' || true)
echo "    Run job ID: ${RUN_JOB_ID:-failed}"

if [[ -z "$RUN_JOB_ID" ]]; then
    echo "ERROR: Failed to submit run job"
    exit 1
fi

if [[ "$NO_CONSUL" == "true" ]]; then
    echo "[5/6] Skipping consul registration (--no-consul)"
else
    echo "[5/6] Submitting consul registration job..."
    echo "    Service name: ${SERVICE_NAME}"
    CONSUL_DEPENDENCY="#SBATCH --dependency=after:${RUN_JOB_ID}"

    ssh "$CLUSTER" bash -s <<EOF
sbatch <<SLURM
#!/bin/bash
#SBATCH --job-name=consul-register
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=2G
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=2
#SBATCH --output=${LOG_DIR}/consul-register-%j.log
#SBATCH --error=${LOG_DIR}/consul-register-%j.err
${CONSUL_DEPENDENCY}
${ACCOUNT_DIRECTIVE}

set -euo pipefail

JOB_STATE=\\\$(sacct -j ${RUN_JOB_ID} --format=State --noheader | head -n1 | awk '{print \\\$1}')
if [[ "\\\$JOB_STATE" != "RUNNING" ]]; then
    echo "Job ${RUN_JOB_ID} not running (state: \\\$JOB_STATE), exiting."
    exit 0
fi

HOSTNAME=\\\$(sacct -j ${RUN_JOB_ID} --format=NodeList --noheader | awk '{print \\\$1}' | head -n 1)
FULL_HOSTNAME=\\\$(dig +short -x "\\\$(getent hosts "\\\$HOSTNAME" | awk '{print \\\$1}')" | head -n1)
[[ -z "\\\$FULL_HOSTNAME" ]] && FULL_HOSTNAME=\\\$HOSTNAME

curl --silent --output /dev/null --request PUT ${CONSUL_ENDPOINT}/v1/agent/service/deregister/${SERVICE_NAME}

TAGS='"user:${CONSUL_SSH_USER}", "proxyjump:${PROXYJUMP}", "ssh"'
IFS=',' read -ra FORWARDS <<< "${LOCAL_FORWARDS}"
for forward in "\\\${FORWARDS[@]}"; do
    forward=\\\$(echo "\\\$forward" | xargs)
    [[ -n "\\\$forward" ]] && TAGS="\\\$TAGS, \"localforward:\\\$forward\""
done

curl --request PUT --data @- ${CONSUL_ENDPOINT}/v1/agent/service/register <<CONSUL
{
  "Name": "${SERVICE_NAME}",
  "Tags": [\\\$TAGS],
  "Address": "\\\$FULL_HOSTNAME",
  "Port": ${CONSUL_PORT}
}
CONSUL
SLURM
EOF
fi

echo "[6/6] Done!"
echo "    Run job: ${RUN_JOB_ID}"
echo "    Service: ${SERVICE_NAME}"
echo "    Logs: ${LOG_DIR}/run-${IMAGE}-${RUN_JOB_ID}.log"
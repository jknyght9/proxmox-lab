#!/usr/bin/env bash

# Colors for terminal outputs
C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[0;34m"

# Functions for colorized output
function info()         { echo -e "${C_BLUE}[+] $*${C_RESET}"; }
function doing()        { echo -e "${C_BLUE}[>] $*${C_RESET}"; }
function success()      { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
function error()        { echo -e "${C_RED}[X] $*${C_RESET}"; }
function warn()         { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
function question()     { echo -e "  ${C_YELLOW}[?] $*${C_RESET}"; }

# Check for required tools and Docker Engine
function checkRequirements() {
  # Check if sshpass is installed
  if ! command -v sshpass >/dev/null 2>&1; then
    error "'sshpass' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install sshpass"
    echo "  macOS (Homebrew): brew install hudochenkov/sshpass/sshpass"
    echo "  Fedora: sudo dnf install sshpass"
    exit 1
  fi
  
  # Check if jq is installed
  if ! command -v jq >/dev/null 2>&1; then
    error "'jq' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install jq"
    echo "  macOS (Homebrew): brew install jq"
    echo "  Fedora: sudo dnf install jq"
    exit 1
  fi

  # Check if Docker Engine is installed
  if ! command -v docker >/dev/null 2>&1; then
    error "'docker' is not installed. Please install Docker Engine."
    echo "  https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Check if Docker Engine is running
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine is installed but not running or not accessible."
    echo "  Make sure the docker service is started:"
    echo "    sudo systemctl start docker"
    echo "  Or check permissions (your user may need to be in the 'docker' group)."
    exit 1
  fi

  success "All requirements met: sshpass, jq, and Docker are available and running."
}

# Display a header banner
function header() {
  clear
  cat << "EOF"
   ___                                       __       _
  / _ \_ __ _____  ___ __ ___   _____  __   / /  __ _| |__
 / /_)/ '__/ _ \ \/ / '_ ` _ \ / _ \ \/ /  / /  / _` | '_ \
/ ___/| | | (_) >  <| | | | | | (_) >  <  / /__| (_| | |_) |
\/    |_|  \___/_/\_\_| |_| |_|\___/_/\_\ \____/\__,_|_.__/

EOF
}

# SSH command wrapper with common options (simple command)
# Arguments: $1 - user, $2 - host, $3 - command
function sshRun() {
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=5 "$1@$2" "$3"
}

# SSH with heredoc/multiline script support (reads from stdin)
# Arguments: $1 - user, $2 - host, remaining args passed to remote bash
# Usage: sshScript user host <<'SCRIPT' ... SCRIPT
#    or: sshScript user host < script.sh
function sshScript() {
  local user="$1"
  local host="$2"
  shift 2
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=5 "$user@$host" bash -s "$@"
}

# SCP wrapper for copying files to remote hosts
# Arguments: $1 - local path, $2 - user, $3 - host, $4 - remote path
function scpTo() {
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$1" "$2@$3:$4"
}

# Prompt user to press any key to continue
function pressAnyKey()  { read -n 1 -s -p "$(question "Press any key to continue")"; echo; }
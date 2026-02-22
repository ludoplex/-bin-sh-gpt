#!/bin/bash

GLOBIGNORE="*"

CHAT_INIT_PROMPT="You are ChatGPT, a Large Language Model trained by OpenAI. You will be answering questions from users. You answer as concisely as possible for each response (e.g. don’t be verbose). If you are generating a list, do not have too many items. Keep the number of items short. Before each user prompt you will be given the chat history in Q&A form. Output your answer directly, with no labels in front. Do not start your answers with A or Anwser. You were trained on data up until 2021. Today's date is $(date +%m/%d/%Y)"

SYSTEM_PROMPT="You are ChatGPT, a large language model trained by OpenAI. Answer as concisely as possible. Current date: $(date +%m/%d/%Y). Knowledge cutoff: 9/1/2021."

COMMAND_GENERATION_PROMPT="You are a Command Line Interface expert and your task is to provide functioning shell commands. Return a CLI command and nothing else - do not send it in a code block, quotes, or anything else, just the pure text CONTAINING ONLY THE COMMAND. If possible, return a one-line bash command or chain many commands together. Return ONLY the command ready to run in the terminal. The command should do the following:"
OPENCLAW_CAPABILITY_PROMPT="You are operating in an OpenClaw-like Unix-native mode. Prefer coherent Unix workflows and native concepts first: shell pipelines, terminal sessions, filesystems, process management, and daemon/service configuration. When asked for an action plan, break work into concrete terminal-first steps and include verification commands."

CHATGPT_CYAN_LABEL="\033[36mchatgpt \033[0m"
PROCESSING_LABEL="\n\033[90mProcessing... \033[0m\033[0K\r"
OVERWRITE_PROCESSING_LINE="             \033[0K\r"
OPENCLAW_MODE=false
OPENCLAW_CONFIG_FILE=""
SKILLS_DIR="${HOME}/.chatgpt/skills"
ACTIVE_SKILLS=""
MCP_SOCKET=""
MCP_FIFO_DIR=""
MCP_REQ_FIFO=""
MCP_RESP_FIFO=""

CHATGPT_STATE_DIR="${HOME}/.local/share/chatgpt"
CHATGPT_HISTORY_FILE="${CHATGPT_STATE_DIR}/history.log"
CHATGPT_SENSITIVE_DB_FILE="${CHATGPT_STATE_DIR}/sensitive.db.enc"
CHATGPT_SENSITIVE_TMP_DB="${CHATGPT_STATE_DIR}/sensitive.db.tmp"

if [[ -z "$OPENAI_KEY" ]]; then
	echo "You need to set your OPENAI_KEY to use this script"
	echo "You can set it temporarily by running this on your terminal: export OPENAI_KEY=YOUR_KEY_HERE"
	exit 1
fi

usage() {
	cat <<EOF2
A simple, lightweight shell script to use OpenAI's Language Models and DALL-E from the terminal without installing Python or Node.js. Open Source and written in 100% Shell (Bash)

https://github.com/0xacx/chatGPT-shell-cli/

By default the script uses the "gpt-3.5-turbo" model. It will upgrade to "gpt-4" when the API is accessible to anyone.

Commands:
  image: - To generate images, start a prompt with image: If you are using iTerm, you can view the image directly in the terminal. Otherwise the script will ask to open the image in your browser.
  history - To view your chat history
  context - Print active Unix/runtime context
  skills - List local skill files from --skills-dir
  skill:<name> - Activate a local skill file for this session
  mcp:<payload> - Send a payload to a local MCP daemon transport
  models - To get a list of the models available at OpenAI API
  model: - To view all the information on a specific model, start a prompt with model: and the model id as it appears in the list of models. For example: "model:text-babbage:001" will get you all the fields for text-babbage:001 model
  command: - To get a command with the specified functionality and run it, just type "command:" and explain what you want to achieve. The script will always ask you if you want to execute the command. i.e.
  "command: show me all files in this directory that have more than 150 lines of code"
  *If a command modifies your file system or dowloads external files the script will show a warning before executing.

Options:
  -i, --init-prompt          Provide initial chat prompt to use in context

  --init-prompt-from-file    Provide initial prompt from file

  -p, --prompt               Provide prompt instead of starting chat

  --prompt-from-file         Provide prompt from file

  -b, --big-prompt           Allow multi-line prompts during chat mode

  -t, --temperature          Temperature

  --max-tokens               Max number of tokens

  -l, --list                 List available openAI models

  -m, --model                Model to use

  -s, --size                 Image size. (The sizes that are accepted by the
                             OpenAI API are 256x256, 512x512, 1024x1024)

  -c, --chat-context         For models that do not support chat context by
                             default (all models except gpt-3.5-turbo and
                             gpt-4), you can enable chat context, for the
                             model to remember your previous questions and
                             its previous answers. It also makes models
                             aware of todays date and what data it was trained
                             on.

  --openclaw-mode            Enable Unix-native terminal-first assistant mode.

  --openclaw-config          Path to a local config/context file to inject
                             into the system prompt when openclaw mode is on.

  --skills-dir               Directory containing local skill text/markdown
                             files (default: ~/.chatgpt/skills)

  --mcp-socket               Unix domain socket used for MCP-style local IPC
                             with external agent/tool daemons.

  --mcp-fifo-dir             Directory containing req.fifo and resp.fifo for
                             MCP-style local FIFO IPC when Unix sockets are
                             unavailable.

  --install-vcs-history-guard  Install pre-commit and post-commit hooks that
                               enforce history outside VCS and readonly mode.
EOF2
}

# error handling function
handle_error() {
	if echo "$1" | jq -e '.error' >/dev/null; then
		echo -e "Your request to Open AI API failed: \033[0;31m$(echo "$1" | jq -r '.error.type')\033[0m"
		echo "$1" | jq -r '.error.message'
		exit 1
	fi
}

list_models() {
	models_response=$(curl https://api.openai.com/v1/models -sS -H "Authorization: Bearer $OPENAI_KEY")
	handle_error "$models_response"
	models_data=$(echo "$models_response" | jq -r -C '.data[] | {id, owned_by, created}')
	echo -e "$OVERWRITE_PROCESSING_LINE"
	echo -e "${CHATGPT_CYAN_LABEL}This is a list of models currently available at OpenAI API:\n ${models_data}"
}

request_to_completions() {
	local prompt="$1"
	curl https://api.openai.com/v1/completions -sS -H 'Content-Type: application/json' -H "Authorization: Bearer $OPENAI_KEY" -d '{
  "model": "'"$MODEL"'",
  "prompt": "'"$prompt"'",
  "max_tokens": '"$MAX_TOKENS"',
  "temperature": '"$TEMPERATURE"'
}'
}

request_to_image() {
	local prompt="$1"
	image_response=$(curl https://api.openai.com/v1/images/generations -sS -H 'Content-Type: application/json' -H "Authorization: Bearer $OPENAI_KEY" -d '{
    "prompt": "'"${prompt#*image:}"'",
    "n": 1,
    "size": "'"$SIZE"'"
}')
}

request_to_chat() {
	local message="$1"
	escaped_system_prompt=$(escape "$SYSTEM_PROMPT")
	curl https://api.openai.com/v1/chat/completions -sS -H 'Content-Type: application/json' -H "Authorization: Bearer $OPENAI_KEY" -d '{
      "model": "'"$MODEL"'",
      "messages": [
          {"role": "system", "content": "'"$escaped_system_prompt"'"},
          '"$message"'
          ],
      "max_tokens": '"$MAX_TOKENS"',
      "temperature": '"$TEMPERATURE"'
      }'
}

build_chat_context() {
	local escaped_request_prompt="$1"
	if [ -z "$chat_context" ]; then
		chat_context="$CHAT_INIT_PROMPT\nQ: $escaped_request_prompt"
	else
		chat_context="$chat_context\nQ: $escaped_request_prompt"
	fi
}

escape() {
	echo "$1" | jq -Rrs 'tojson[1:-1]'
}

apply_openclaw_prompt() {
	if [ "$OPENCLAW_MODE" != true ]; then
		return
	fi

	local shell_name="${SHELL##*/}"
	local os_name="${OSTYPE:-unknown}"
	local context="${OPENCLAW_CAPABILITY_PROMPT}\nRuntime context:\n- cwd: ${PWD}\n- shell: ${shell_name}\n- user: ${USER:-unknown}\n- host: ${HOSTNAME:-unknown}\n- os: ${os_name}"

	if [ -n "$OPENCLAW_CONFIG_FILE" ] && [ -r "$OPENCLAW_CONFIG_FILE" ]; then
		local config_content
		config_content=$(<"$OPENCLAW_CONFIG_FILE")
		context+="\n\nOperator config:\n${config_content}"
	fi

	SYSTEM_PROMPT="${SYSTEM_PROMPT}\n\n${context}"
}

print_response_text() {
	local response_text="$1"
	echo -e "$OVERWRITE_PROCESSING_LINE"
	if command -v glow &>/dev/null; then
		echo -e "${CHATGPT_CYAN_LABEL}"
		echo "${response_text}" | glow -
	else
		echo -e "${CHATGPT_CYAN_LABEL}${response_text}" | fold -s -w "${COLUMNS:-80}"
	fi
}

ensure_history_outside_repo() {
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [ -z "$root" ]; then
		return 0
	fi
	case "$CHATGPT_HISTORY_FILE" in
		"$root"/*)
			mkdir -p "$CHATGPT_STATE_DIR"
			if [ -f "$CHATGPT_HISTORY_FILE" ]; then
				mv "$CHATGPT_HISTORY_FILE" "${CHATGPT_STATE_DIR}/history.log"
			fi
			CHATGPT_HISTORY_FILE="${CHATGPT_STATE_DIR}/history.log"
			;;
	esac
}

initialize_history_store() {
	mkdir -p "$CHATGPT_STATE_DIR"
	ensure_history_outside_repo
	if [ ! -f "$CHATGPT_HISTORY_FILE" ]; then
		: >"$CHATGPT_HISTORY_FILE"
	fi
	chmod 400 "$CHATGPT_HISTORY_FILE"
	if [ ! -f "$CHATGPT_SENSITIVE_DB_FILE" ]; then
		: >"$CHATGPT_SENSITIVE_TMP_DB"
		encrypt_sensitive_db
	fi
}

sensitive_db_passphrase() {
	if [ -n "$CHATGPT_SENSITIVE_DB_KEY" ]; then
		echo "$CHATGPT_SENSITIVE_DB_KEY"
	else
		echo "$OPENAI_KEY"
	fi
}

decrypt_sensitive_db() {
	local passphrase
	passphrase=$(sensitive_db_passphrase)
	if [ ! -s "$CHATGPT_SENSITIVE_DB_FILE" ]; then
		: >"$CHATGPT_SENSITIVE_TMP_DB"
		return 0
	fi
	openssl enc -d -aes-256-cbc -pbkdf2 -salt -in "$CHATGPT_SENSITIVE_DB_FILE" -out "$CHATGPT_SENSITIVE_TMP_DB" -pass pass:"$passphrase" 2>/dev/null || : >"$CHATGPT_SENSITIVE_TMP_DB"
}

encrypt_sensitive_db() {
	local passphrase
	passphrase=$(sensitive_db_passphrase)
	openssl enc -e -aes-256-cbc -pbkdf2 -salt -in "$CHATGPT_SENSITIVE_TMP_DB" -out "$CHATGPT_SENSITIVE_DB_FILE" -pass pass:"$passphrase"
	chmod 600 "$CHATGPT_SENSITIVE_DB_FILE"
}

record_sensitive_string() {
	local value="$1"
	local path="$2"
	local device_id
	device_id="$(hostname 2>/dev/null || echo unknown-device)"
	decrypt_sensitive_db
	local next_id
	next_id=$(( $(wc -l < "$CHATGPT_SENSITIVE_TMP_DB" 2>/dev/null || echo 0) + 1 ))
	printf '%s|%s|%s|%s\n' "SEN-$next_id" "$path" "$device_id" "$value" >>"$CHATGPT_SENSITIVE_TMP_DB"
	encrypt_sensitive_db
	rm -f "$CHATGPT_SENSITIVE_TMP_DB"
	echo "[REDACTED:SEN-$next_id]"
}

redact_sensitive_data() {
	local content="$1"
	local redacted="$content"
	local re
	for re in 'sk-[A-Za-z0-9_-]\{20,\}' 'AKIA[0-9A-Z]\{16\}' '-----BEGIN [A-Z ]*PRIVATE KEY-----'; do
		local matches
		matches=$(printf '%s\n' "$redacted" | sed -n "s/.*\($re\).*/\1/p" | sort -u)
		if [ -n "$matches" ]; then
			while IFS= read -r m; do
				[ -z "$m" ] && continue
				token=$(record_sensitive_string "$m" "$CHATGPT_HISTORY_FILE")
				redacted=${redacted//"$m"/"$token"}
			done <<<"$matches"
		fi
	done
	printf '%s' "$redacted"
}

append_history_entry() {
	local user_prompt="$1"
	local assistant_reply="$2"
	local safe_prompt safe_reply
	safe_prompt=$(redact_sensitive_data "$user_prompt")
	safe_reply=$(redact_sensitive_data "$assistant_reply")
	chmod 600 "$CHATGPT_HISTORY_FILE"
	printf '%s %s \n%s \n\n' "$(date +"%Y-%m-%d %H:%M")" "$safe_prompt" "$safe_reply" >>"$CHATGPT_HISTORY_FILE"
	chmod 400 "$CHATGPT_HISTORY_FILE"
}

resolve_skill_file() {
	local skill_name="$1"
	local candidate
	for candidate in "$SKILLS_DIR/$skill_name" "$SKILLS_DIR/$skill_name.md" "$SKILLS_DIR/$skill_name.txt"; do
		if [ -r "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

list_local_skills() {
	if [ ! -d "$SKILLS_DIR" ]; then
		echo -e "${CHATGPT_CYAN_LABEL}No skills directory found at $SKILLS_DIR"
		return
	fi
	echo -e "${CHATGPT_CYAN_LABEL}Available local skills in $SKILLS_DIR:"
	find "$SKILLS_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) -printf '%f\n' | sed -E 's/\.(md|txt)$//' | sort -u
}

activate_skill() {
	local skill_name="$1"
	local skill_file
	skill_file=$(resolve_skill_file "$skill_name") || return 1
	local skill_content
	skill_content=$(<"$skill_file")
	SYSTEM_PROMPT="${SYSTEM_PROMPT}\n\nSkill (${skill_name}):\n${skill_content}"
	ACTIVE_SKILLS="${ACTIVE_SKILLS}${ACTIVE_SKILLS:+, }${skill_name}"
	echo -e "${CHATGPT_CYAN_LABEL}Activated skill: ${skill_name}"
}

send_mcp_message() {
	local payload="$1"
	if [ -n "$MCP_SOCKET" ]; then
		if [ ! -S "$MCP_SOCKET" ]; then
			echo -e "${CHATGPT_CYAN_LABEL}MCP socket not found: $MCP_SOCKET" >&2
			return 1
		fi
		if ! command -v socat >/dev/null 2>&1; then
			echo -e "${CHATGPT_CYAN_LABEL}socat is required for Unix socket MCP transport" >&2
			return 1
		fi
		printf '%s\n' "$payload" | socat - UNIX-CONNECT:"$MCP_SOCKET"
		return $?
	fi

	if [ -n "$MCP_REQ_FIFO" ] && [ -n "$MCP_RESP_FIFO" ] && [ -p "$MCP_REQ_FIFO" ] && [ -p "$MCP_RESP_FIFO" ]; then
		printf '%s\n' "$payload" >"$MCP_REQ_FIFO"
		head -n 1 <"$MCP_RESP_FIFO"
		return $?
	fi

	echo -e "${CHATGPT_CYAN_LABEL}No MCP transport configured. Use --mcp-socket /path.sock or --mcp-fifo-dir /path" >&2
	return 1
}

init_mcp_fifo_paths() {
	[ -z "$MCP_FIFO_DIR" ] && return
	MCP_REQ_FIFO="$MCP_FIFO_DIR/req.fifo"
	MCP_RESP_FIFO="$MCP_FIFO_DIR/resp.fifo"
}

show_unix_context() {
	echo -e "${CHATGPT_CYAN_LABEL}Unix context"
	echo "cwd=$PWD"
	echo "shell=${SHELL##*/}"
	echo "user=${USER:-unknown}"
	echo "host=${HOSTNAME:-unknown}"
	echo "skills_dir=$SKILLS_DIR"
	echo "history_file=$CHATGPT_HISTORY_FILE"
	echo "mcp_socket=${MCP_SOCKET:-unset}"
	echo "mcp_fifo_dir=${MCP_FIFO_DIR:-unset}"
	echo "active_skills=${ACTIVE_SKILLS:-none}"
}

install_vcs_history_guard() {
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [ -z "$root" ]; then
		echo "Not in a git repository"
		return 1
	fi
	mkdir -p "$root/.git/hooks"
	cat >"$root/.git/hooks/pre-commit" <<'HOOKPRE'
#!/bin/bash
"$(git rev-parse --show-toplevel)/internal_dev/vcs_history_guard.sh" pre || exit 1
HOOKPRE
	cat >"$root/.git/hooks/post-commit" <<'HOOKPOST'
#!/bin/bash
"$(git rev-parse --show-toplevel)/internal_dev/vcs_history_guard.sh" post || exit 1
HOOKPOST
	chmod +x "$root/.git/hooks/pre-commit" "$root/.git/hooks/post-commit"
	echo "Installed VCS history guard hooks"
}

maintain_chat_context() {
	local escaped_response_data="$1"
	chat_context="$chat_context${chat_context:+\n}\nA: $escaped_response_data"
	while (($(echo "$chat_context" | wc -c) * 1, 3 > (MAX_TOKENS - 100))); do
		chat_context=$(echo "$chat_context" | sed -n '/Q:/,$p' | tail -n +2)
		chat_context="$CHAT_INIT_PROMPT $chat_context"
	done
}

build_user_chat_message() {
	local escaped_request_prompt="$1"
	if [ -z "$chat_message" ]; then
		chat_message="{\"role\": \"user\", \"content\": \"$escaped_request_prompt\"}"
	else
		chat_message="$chat_message, {\"role\": \"user\", \"content\": \"$escaped_request_prompt\"}"
	fi
}

add_assistant_response_to_chat_message() {
	local escaped_response_data="$1"
	chat_message="$chat_message, {\"role\": \"assistant\", \"content\": \"$escaped_response_data\"}"
	local chat_message_json="[ $chat_message ]"
	while (($(echo "$chat_message" | wc -c) * 1, 3 > (MAX_TOKENS - 100))); do
		chat_message=$(echo "$chat_message_json" | jq -c '.[2:] | .[] | {role, content}')
	done
}

while [[ "$#" -gt 0 ]]; do
	case $1 in
	-i | --init-prompt)
		CHAT_INIT_PROMPT="$2"; SYSTEM_PROMPT="$2"; CONTEXT=true; shift; shift ;;
	--init-prompt-from-file)
		CHAT_INIT_PROMPT=$(cat "$2"); SYSTEM_PROMPT=$(cat "$2"); CONTEXT=true; shift; shift ;;
	-p | --prompt)
		prompt="$2"; shift; shift ;;
	--prompt-from-file)
		prompt=$(cat "$2"); shift; shift ;;
	-t | --temperature)
		TEMPERATURE="$2"; shift; shift ;;
	--max-tokens)
		MAX_TOKENS="$2"; shift; shift ;;
	-l | --list)
		list_models; exit 0 ;;
	-m | --model)
		MODEL="$2"; shift; shift ;;
	-s | --size)
		SIZE="$2"; shift; shift ;;
	--multi-line-prompt)
		MULTI_LINE_PROMPT=true; shift ;;
	-c | --chat-context)
		CONTEXT=true; shift ;;
	--openclaw-mode)
		OPENCLAW_MODE=true; shift ;;
	--openclaw-config)
		OPENCLAW_CONFIG_FILE="$2"; OPENCLAW_MODE=true; shift; shift ;;
	--skills-dir)
		SKILLS_DIR="$2"; shift; shift ;;
	--mcp-socket)
		MCP_SOCKET="$2"; shift; shift ;;
	--mcp-fifo-dir)
		MCP_FIFO_DIR="$2"; shift; shift ;;
	--install-vcs-history-guard)
		install_vcs_history_guard; exit $? ;;
	-h | --help)
		usage; exit 0 ;;
	*)
		echo "Unknown parameter: $1"; exit 1 ;;
	esac
done

apply_openclaw_prompt
init_mcp_fifo_paths
TEMPERATURE=${TEMPERATURE:-0.7}
MAX_TOKENS=${MAX_TOKENS:-1024}
MODEL=${MODEL:-gpt-3.5-turbo}
SIZE=${SIZE:-512x512}
CONTEXT=${CONTEXT:-false}
MULTI_LINE_PROMPT=${MULTI_LINE_PROMPT:-false}

if [ "$MULTI_LINE_PROMPT" = true ]; then
	USER_INPUT_TEMP_FILE=$(mktemp)
	trap 'rm -f ${USER_INPUT_TEMP_FILE}' EXIT
fi

initialize_history_store || { echo "History store is required and could not be initialized"; exit 1; }

running=true
if [ -n "$prompt" ]; then
	pipe_mode_prompt=${prompt}
elif [ -t 0 ]; then
	echo -e "Welcome to chatgpt. You can quit with '\033[36mexit\033[0m' or '\033[36mq\033[0m'."
else
	pipe_mode_prompt+=$(cat -)
fi

while $running; do
	if [ -z "$pipe_mode_prompt" ]; then
		if [ "$MULTI_LINE_PROMPT" = true ]; then
			echo -e "\nEnter a prompt: (Press Enter then Ctrl-D to send)"
			cat >"${USER_INPUT_TEMP_FILE}"
			prompt=$(<"${USER_INPUT_TEMP_FILE}")
		else
			echo -e "\nEnter a prompt:"
			read -e prompt
		fi
		if [[ ! $prompt =~ ^(exit|q)$ ]]; then
			echo -ne "$PROCESSING_LABEL"
		fi
	else
		prompt=${pipe_mode_prompt}
		running=false
		CHATGPT_CYAN_LABEL=""
	fi

	if [[ $prompt =~ ^(exit|q)$ ]]; then
		running=false
	elif [[ "$prompt" == "skills" ]]; then
		list_local_skills
	elif [[ "$prompt" == "context" ]]; then
		show_unix_context
	elif [[ "$prompt" =~ ^skill: ]]; then
		skill_name="${prompt#*skill:}"
		if ! activate_skill "$skill_name"; then
			echo -e "${CHATGPT_CYAN_LABEL}Skill not found: ${skill_name}"
		fi
	elif [[ "$prompt" =~ ^mcp: ]]; then
		mcp_payload="${prompt#mcp:}"
		echo -e "$OVERWRITE_PROCESSING_LINE"
		if mcp_response=$(send_mcp_message "$mcp_payload"); then
			echo -e "${CHATGPT_CYAN_LABEL}${mcp_response}" | fold -s -w "${COLUMNS:-80}"
			append_history_entry "$prompt" "$mcp_response"
		fi
	elif [[ "$prompt" =~ ^image: ]]; then
		request_to_image "$prompt"
		handle_error "$image_response"
		image_url=$(echo "$image_response" | jq -r '.data[0].url')
		echo -e "$OVERWRITE_PROCESSING_LINE"
		echo -e "${CHATGPT_CYAN_LABEL}Your image was created. \n\nLink: ${image_url}\n"
		if [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
			curl -sS "$image_url" -o temp_image.png
			imgcat temp_image.png
			rm temp_image.png
		elif [[ "$TERM" == "xterm-kitty" ]]; then
			curl -sS "$image_url" -o temp_image.png
			kitty +kitten icat temp_image.png
			rm temp_image.png
		else
			echo "Would you like to open it? (Yes/No)"
			read -e answer
			if [ "$answer" == "Yes" ] || [ "$answer" == "yes" ] || [ "$answer" == "y" ] || [ "$answer" == "Y" ] || [ "$answer" == "ok" ]; then
				open "${image_url}"
			fi
		fi
	elif [[ "$prompt" == "history" ]]; then
		echo
		cat "$CHATGPT_HISTORY_FILE"
	elif [[ "$prompt" == "models" ]]; then
		list_models
	elif [[ "$prompt" =~ ^model: ]]; then
		models_response=$(curl https://api.openai.com/v1/models -sS -H "Authorization: Bearer $OPENAI_KEY")
		handle_error "$models_response"
		model_data=$(echo "$models_response" | jq -r -C '.data[] | select(.id=="'"${prompt#*model:}"'")')
		echo -e "$OVERWRITE_PROCESSING_LINE"
		echo -e "${CHATGPT_CYAN_LABEL}Complete details for model: ${prompt#*model:}\n ${model_data}"
	elif [[ "$prompt" =~ ^command: ]]; then
		escaped_prompt=$(escape "$prompt")
		escaped_prompt=${escaped_prompt#command:}
		request_prompt=$COMMAND_GENERATION_PROMPT$escaped_prompt
		build_user_chat_message "$request_prompt"
		response=$(request_to_chat "$chat_message")
		handle_error "$response"
		response_data=$(echo "$response" | jq -r '.choices[].message.content')
		echo -e "$OVERWRITE_PROCESSING_LINE"
		echo -e "${CHATGPT_CYAN_LABEL} ${response_data}" | fold -s -w "${COLUMNS:-80}"
		dangerous_commands=("rm" ">" "mv" "mkfs" ":(){:|:&};" "dd" "chmod" "wget" "curl")
		for dangerous_command in "${dangerous_commands[@]}"; do
			if [[ "$response_data" == *"$dangerous_command"* ]]; then
				echo "Warning! This command can change your file system or download external scripts & data. Please do not execute code that you don't understand completely."
			fi
		done
		echo "Would you like to execute it? (Yes/No)"
		read run_answer
		if [ "$run_answer" == "Yes" ] || [ "$run_answer" == "yes" ] || [ "$run_answer" == "y" ] || [ "$run_answer" == "Y" ]; then
			echo -e "\nExecuting command: $response_data\n"
			eval "$response_data"
		fi
		add_assistant_response_to_chat_message "$(escape "$response_data")"
		append_history_entry "$prompt" "$response_data"
	elif [[ "$MODEL" =~ ^gpt- ]]; then
		request_prompt=$(escape "$prompt")
		build_user_chat_message "$request_prompt"
		response=$(request_to_chat "$chat_message")
		handle_error "$response"
		response_data=$(echo "$response" | jq -r '.choices[].message.content')
		print_response_text "$response_data"
		add_assistant_response_to_chat_message "$(escape "$response_data")"
		append_history_entry "$prompt" "$response_data"
	else
		request_prompt=$(escape "$prompt")
		if [ "$CONTEXT" = true ]; then
			build_chat_context "$request_prompt"
		fi
		response=$(request_to_completions "$request_prompt")
		handle_error "$response"
		response_data=$(echo "$response" | jq -r '.choices[].text')
		formatted_text=$(echo "$response_data" | sed '1,2d; s/^A://g')
		print_response_text "$formatted_text"
		if [ "$CONTEXT" = true ]; then
			maintain_chat_context "$(escape "$response_data")"
		fi
		append_history_entry "$prompt" "$response_data"
	fi
done

#!/usr/bin/env bash

CONFIG_DIR="$HOME/.s3_backup_tool"
ACCOUNTS_DIR="$CONFIG_DIR/accounts"
TAG="# S3_BACKUP"
KEEP_COUNT="${S3_KEEP_COUNT:-3}"

RAW_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_PATH="$RAW_SCRIPT_PATH"
INSTALL_PATH="${S3_BACKUP_INSTALL_PATH:-/root/s3.sh}"
SCRIPT_URL="${S3_BACKUP_SCRIPT_URL:-}"

mkdir -p "$ACCOUNTS_DIR"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo
    read -rp "按回车键继续..." _
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

trim_slashes() {
    local value="$1"
    while [[ "$value" == /* ]]; do
        value="${value#/}"
    done
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    printf '%s' "$value"
}

normalize_bucket_input() {
    local value="$1"
    value="${value#s3://}"
    value="$(trim_slashes "$value")"

    NORMALIZED_BUCKET="$value"
    NORMALIZED_BUCKET_PREFIX=""

    if [[ "$value" == */* ]]; then
        NORMALIZED_BUCKET="${value%%/*}"
        NORMALIZED_BUCKET_PREFIX="$(trim_slashes "${value#*/}")"
    fi
}

normalize_s3_key_input() {
    local value="$1"
    value="${value#s3://}"
    value="$(trim_slashes "$value")"

    if [[ "$value" == "$S3_BUCKET" ]]; then
        value=""
    elif [[ "$value" == "$S3_BUCKET/"* ]]; then
        value="${value#"$S3_BUCKET"/}"
    elif [[ "$value" == */* && "$1" == s3://* ]]; then
        local input_bucket="${value%%/*}"
        echo "提示：当前账号 Bucket 是 $S3_BUCKET，已忽略你输入的完整 S3 地址里的 Bucket：$input_bucket" >&2
        value="${value#*/}"
    fi

    trim_slashes "$value"
}

safe_name() {
    local value="$1"
    value="${value// /_}"
    value="$(printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_')"
    value="${value##_}"
    value="${value%%_}"
    [[ -n "$value" ]] || value="backup"
    printf '%s' "$value"
}

path_hash() {
    printf '%s' "$1" | cksum | awk '{print $1}'
}

normalize_script_path() {
    if [[ "$SCRIPT_PATH" == /dev/fd/* ]] || [[ "$SCRIPT_PATH" == /proc/*/fd/* ]] || [[ "$SCRIPT_PATH" == *"pipe:"* ]]; then
        if [[ ! -f "$INSTALL_PATH" ]]; then
            echo "检测到临时方式运行，正在安装脚本到：$INSTALL_PATH"
            if [[ -n "$SCRIPT_URL" ]] && command_exists curl; then
                curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH" || cp "$RAW_SCRIPT_PATH" "$INSTALL_PATH"
            elif [[ -n "$SCRIPT_URL" ]] && command_exists wget; then
                wget -qO "$INSTALL_PATH" "$SCRIPT_URL" || cp "$RAW_SCRIPT_PATH" "$INSTALL_PATH"
            else
                cp "$RAW_SCRIPT_PATH" "$INSTALL_PATH"
            fi
            chmod +x "$INSTALL_PATH"
            echo "安装完成，以后 crontab 将使用：$INSTALL_PATH"
        fi
        SCRIPT_PATH="$INSTALL_PATH"
    fi
}

normalize_script_path

ensure_command() {
    local cmd="$1"
    local deb_pkg="$2"
    local rhel_pkg="$3"
    local other_pkg="$4"

    if command_exists "$cmd"; then
        return 0
    fi

    echo "未检测到依赖：$cmd，尝试自动安装..."

    if command_exists apt-get; then
        local pkg="${deb_pkg:-$cmd}"
        sudo apt-get update && sudo apt-get install -y "$pkg"
    elif command_exists yum; then
        local pkg="${rhel_pkg:-$cmd}"
        sudo yum install -y "$pkg"
    elif command_exists dnf; then
        local pkg="${rhel_pkg:-$cmd}"
        sudo dnf install -y "$pkg"
    elif command_exists zypper; then
        local pkg="${other_pkg:-$cmd}"
        sudo zypper install -y "$pkg"
    elif command_exists pacman; then
        local pkg="${other_pkg:-$cmd}"
        sudo pacman -Sy --noconfirm "$pkg"
    else
        echo "未找到可用包管理器，请手动安装：$cmd"
        return 1
    fi

    if command_exists "$cmd"; then
        echo "$cmd 安装成功。"
        return 0
    fi

    echo "$cmd 自动安装失败，请手动安装后重试。"
    return 1
}

check_dependencies() {
    ensure_command aws awscli awscli aws-cli || exit 1
    ensure_command tar tar tar tar || exit 1
    ensure_command gzip gzip gzip gzip || exit 1
    ensure_command crontab cron cronie cron || true
}

is_s3_configured() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob
    [[ ${#files[@]} -gt 0 ]]
}

get_s3_count() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob
    echo ${#files[@]}
}

write_account_file() {
    local file="$1"
    {
        printf 'ACCOUNT_ID=%q\n' "$ACCOUNT_ID"
        printf 'S3_ACCESS_KEY=%q\n' "$S3_ACCESS_KEY"
        printf 'S3_SECRET_KEY=%q\n' "$S3_SECRET_KEY"
        printf 'S3_REGION=%q\n' "$S3_REGION"
        printf 'S3_BUCKET=%q\n' "$S3_BUCKET"
        printf 'S3_PREFIX=%q\n' "$S3_PREFIX"
        printf 'S3_ENDPOINT_URL=%q\n' "$S3_ENDPOINT_URL"
    } > "$file"
    chmod 600 "$file"
}

load_s3_account() {
    local account_id="$1"
    local file="$ACCOUNTS_DIR/$account_id.conf"
    if [[ ! -f "$file" ]]; then
        echo "找不到账号配置：$account_id"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$file"
    S3_REGION="${S3_REGION:-us-east-1}"
    S3_PREFIX="$(trim_slashes "${S3_PREFIX:-}")"
    S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
}

build_aws_args() {
    AWS_EXTRA_ARGS=()
    if [[ -n "${S3_ENDPOINT_URL:-}" ]]; then
        AWS_EXTRA_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")
    fi
}

run_aws() {
    build_aws_args
    AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    AWS_DEFAULT_REGION="$S3_REGION" \
    aws "${AWS_EXTRA_ARGS[@]}" "$@"
}

fetch_s3_buckets() {
    {
        run_aws s3api list-buckets --output text --query 'Buckets[].Name' 2>/dev/null \
            | tr '\t ' '\n' \
            | awk 'NF'
        run_aws s3 ls 2>/dev/null \
            | awk 'NF >= 3 {print $3}'
    } | awk 'NF && !seen[$0]++'
}

read_manual_bucket() {
    local var_name="$1"
    local prompt="${2:-请输入 Bucket / 存储桶名称：}"
    local value

    read -rp "$prompt " value
    normalize_bucket_input "$value"

    if [[ -z "$NORMALIZED_BUCKET" ]]; then
        echo "Bucket 不能为空。"
        return 1
    fi

    printf -v "$var_name" '%s' "$NORMALIZED_BUCKET"
    SELECTED_BUCKET_PREFIX="$NORMALIZED_BUCKET_PREFIX"
    return 0
}

select_s3_bucket() {
    local var_name="$1"
    local current="${2:-}"
    local buckets=()
    local i choice selected

    SELECTED_BUCKET_PREFIX=""
    echo
    echo "正在拉取 Bucket / 存储桶列表..."
    mapfile -t buckets < <(fetch_s3_buckets)

    if [[ ${#buckets[@]} -eq 0 ]]; then
        echo "未能自动拉取 Bucket 列表，可能是权限不足或兼容服务不支持 ListBuckets。"
        read_manual_bucket "$var_name" "请手动输入 Bucket / 存储桶名称（也可填 s3://bucket/path）："
        return $?
    fi

    echo "可用 Bucket / 存储桶："
    i=1
    for selected in "${buckets[@]}"; do
        if [[ -n "$current" && "$selected" == "$current" ]]; then
            echo "[$i] $selected（当前）"
        else
            echo "[$i] $selected"
        fi
        i=$((i + 1))
    done
    echo "[m] 手动输入"
    if [[ -n "$current" ]]; then
        echo "[0] 保持当前：$current"
    else
        echo "[0] 取消"
    fi

    while true; do
        read -rp "请输入 Bucket 序号： " choice
        case "$choice" in
            0)
                if [[ -n "$current" ]]; then
                    printf -v "$var_name" '%s' "$current"
                    return 0
                fi
                return 1
                ;;
            m|M)
                read_manual_bucket "$var_name" "请手动输入 Bucket / 存储桶名称（也可填 s3://bucket/path）："
                return $?
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#buckets[@]} )); then
                    printf -v "$var_name" '%s' "${buckets[$((choice - 1))]}"
                    return 0
                fi
                echo "输入编号无效。"
                ;;
        esac
    done
}

s3_uri_for() {
    local extra="$1"
    local prefix
    local extra_clean

    prefix="$(trim_slashes "${S3_PREFIX:-}")"
    extra_clean="$(normalize_s3_key_input "$extra")"

    if [[ -n "$prefix" && -n "$extra_clean" ]]; then
        printf 's3://%s/%s/%s' "$S3_BUCKET" "$prefix" "$extra_clean"
    elif [[ -n "$prefix" ]]; then
        printf 's3://%s/%s' "$S3_BUCKET" "$prefix"
    elif [[ -n "$extra_clean" ]]; then
        printf 's3://%s/%s' "$S3_BUCKET" "$extra_clean"
    else
        printf 's3://%s' "$S3_BUCKET"
    fi
}

add_s3_account() {
    echo "======================================="
    echo "新增 S3 账号"
    echo "======================================="

    read -rp "为此账号起一个名称（例如 main、backup1）： " ACCOUNT_ID
    ACCOUNT_ID="${ACCOUNT_ID// /_}"

    if [[ -z "$ACCOUNT_ID" ]]; then
        echo "账号名称不能为空。"
        pause
        return
    fi

    local file="$ACCOUNTS_DIR/$ACCOUNT_ID.conf"
    if [[ -f "$file" ]]; then
        echo "已存在同名账号配置，将覆盖该账号。"
    fi

    read -rp "S3 Region（默认 us-east-1，R2 可填 auto）： " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"

    read -rp "Endpoint URL（AWS S3 可留空，R2/MinIO/Backblaze 请填写）： " S3_ENDPOINT_URL
    read -rp "Access Key ID： " S3_ACCESS_KEY
    read -rp "Secret Access Key： " S3_SECRET_KEY

    if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
        echo "Access Key 和 Secret Key 不能为空。"
        pause
        return
    fi

    S3_BUCKET=""
    select_s3_bucket S3_BUCKET "" || { pause; return; }

    if [[ -n "$SELECTED_BUCKET_PREFIX" ]]; then
        echo "检测到你输入了 s3://bucket/path 或 bucket/path，已拆分："
        echo "  Bucket：$S3_BUCKET"
        echo "  可选基础前缀：$SELECTED_BUCKET_PREFIX"
    fi

    local prefix_default="$SELECTED_BUCKET_PREFIX"
    if [[ -n "$prefix_default" ]]; then
        read -rp "可选基础前缀（默认 $prefix_default，通常可留空；输入 / 表示存储桶根目录）： " S3_PREFIX
        S3_PREFIX="${S3_PREFIX:-$prefix_default}"
    else
        read -rp "可选基础前缀（通常留空；输入 / 表示存储桶根目录）： " S3_PREFIX
    fi
    if [[ "$S3_PREFIX" == "/" ]]; then
        S3_PREFIX=""
    else
        S3_PREFIX="$(trim_slashes "$S3_PREFIX")"
    fi

    write_account_file "$file"
    echo "账号已保存：$ACCOUNT_ID（Bucket：$S3_BUCKET，基础前缀：${S3_PREFIX:-/}）"
    pause
}

show_s3_accounts() {
    echo "======================================="
    echo "账号列表"
    echo "======================================="

    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "当前没有任何账号配置。"
        pause
        return
    fi

    local i=1
    local f
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        echo "[$i] 账号：$ACCOUNT_ID | Bucket：$S3_BUCKET | Region：${S3_REGION:-us-east-1} | 基础前缀：${S3_PREFIX:-/} | Endpoint：${S3_ENDPOINT_URL:-AWS默认}"
        i=$((i + 1))
    done

    pause
}

delete_s3_account() {
    echo "======================================="
    echo "删除账号"
    echo "======================================="

    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "当前没有可删除的账号。"
        pause
        return
    fi

    local i=1
    declare -a ACCOUNT_IDS
    local f
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        ACCOUNT_IDS[$i]="$ACCOUNT_ID"
        echo "[$i] 账号：$ACCOUNT_ID | Bucket：$S3_BUCKET | 基础前缀：${S3_PREFIX:-/}"
        i=$((i + 1))
    done

    read -rp "请输入要删除的账号编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${ACCOUNT_IDS[$choice]}" ]]; then
        echo "输入编号无效。"
        pause
        return
    fi

    local target_id="${ACCOUNT_IDS[$choice]}"
    local file="$ACCOUNTS_DIR/$target_id.conf"

    read -rp "确认删除账号 [$target_id] 以及它的定时任务吗？(y/N)： " yn
    case "$yn" in
        y|Y)
            rm -f "$file"
            if command_exists crontab; then
                local current
                current=$(crontab -l 2>/dev/null || true)
                if [[ -n "$current" ]]; then
                    echo "$current" | grep -vF "$TAG[$target_id]" | crontab -
                fi
            fi
            echo "已删除账号 [$target_id] 及其相关定时任务。"
            ;;
        *)
            echo "已取消删除。"
            ;;
    esac
    pause
}

CHOSEN_ACCOUNT_ID=""

select_s3_account() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "当前没有账号，请先添加。"
        return 1
    fi

    echo "======================================="
    echo "可用账号列表"
    echo "======================================="

    local i=1
    declare -a ACCOUNT_IDS
    local f
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        ACCOUNT_IDS[$i]="$ACCOUNT_ID"
        echo "[$i] 账号：$ACCOUNT_ID | Bucket：$S3_BUCKET | 基础前缀：${S3_PREFIX:-/}"
        i=$((i + 1))
    done

    echo
    read -rp "请输入账号编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${ACCOUNT_IDS[$choice]}" ]]; then
        echo "输入编号无效。"
        return 1
    fi

    CHOSEN_ACCOUNT_ID="${ACCOUNT_IDS[$choice]}"
    return 0
}

browse_s3_with_account() {
    CHOSEN_ACCOUNT_ID=""
    select_s3_account || { pause; return; }
    local ACCOUNT_ID="$CHOSEN_ACCOUNT_ID"

    load_s3_account "$ACCOUNT_ID" || { pause; return; }

    while true; do
        clear
        echo "======================================="
        echo "S3 远程浏览 / 下载 / 删除"
        echo "======================================="
        echo "当前账号：$ACCOUNT_ID | Bucket：$S3_BUCKET | 基础前缀：${S3_PREFIX:-/}"
        echo
        echo "1) 列出某个远程目录内容"
        echo "2) 下载远程文件到本地"
        echo "3) 下载远程目录到本地"
        echo "4) 删除远程文件"
        echo "5) 删除远程目录"
        echo "0) 返回上一层"
        echo
        read -rp "请输入选项编号： " sub

        case "$sub" in
            1)
                read -rp "请输入 Bucket 内目录/前缀（例如 / 或 backups/www）： " REMOTE_DIR
                local uri
                uri="$(s3_uri_for "$REMOTE_DIR")"
                echo "$uri 下的内容："
                echo "---------------------------------------"
                run_aws s3 ls "$uri/"
                echo "---------------------------------------"
                pause
                ;;
            2)
                read -rp "请输入文件所在的 Bucket 内目录/前缀（例如 / 或 backup/www）： " RDIR
                read -rp "请输入远程文件名（例如 app_20260529_033000.tar.gz）： " RFN
                read -rp "请输入下载到本地的目录（例如 /root/download）： " LDIR

                if [[ -z "$RFN" || -z "$LDIR" ]]; then
                    echo "文件名和本地目录不能为空。"
                    pause
                    continue
                fi

                mkdir -p "$LDIR"
                local src_uri
                src_uri="$(s3_uri_for "$RDIR")/$RFN"
                read -rp "确认下载 $src_uri 到 $LDIR 并覆盖同名文件吗？(y/N)： " yn_dl
                case "$yn_dl" in
                    y|Y)
                        if run_aws s3 cp "$src_uri" "$LDIR/$RFN"; then
                            echo "文件已下载到：$LDIR/$RFN"
                        else
                            echo "下载失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "已取消下载。"
                        pause
                        ;;
                esac
                ;;
            3)
                read -rp "请输入要下载的 Bucket 内目录/前缀（例如 / 或 backup/www）： " RDIR
                read -rp "请输入下载到本地的目录（例如 /root/download）： " LDIR

                if [[ -z "$LDIR" ]]; then
                    echo "本地目录不能为空。"
                    pause
                    continue
                fi

                mkdir -p "$LDIR"
                local dir_uri
                dir_uri="$(s3_uri_for "$RDIR")"
                read -rp "确认同步下载整个目录 $dir_uri 到本地 $LDIR 吗？(y/N)： " yn_dir
                case "$yn_dir" in
                    y|Y)
                        if run_aws s3 sync "$dir_uri" "$LDIR"; then
                            echo "目录已下载到：$LDIR"
                        else
                            echo "目录下载失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "已取消目录下载。"
                        pause
                        ;;
                esac
                ;;
            4)
                read -rp "请输入文件所在的 Bucket 内目录/前缀（例如 / 或 backup/www）： " REMOTE_DIR
                read -rp "请输入要删除的文件名： " REMOTE_FILE

                if [[ -z "$REMOTE_FILE" ]]; then
                    echo "文件名不能为空。"
                    pause
                    continue
                fi

                local file_uri
                file_uri="$(s3_uri_for "$REMOTE_DIR")/$REMOTE_FILE"
                read -rp "确认删除远程文件 $file_uri 吗？此操作不可恢复！(y/N)： " yn
                case "$yn" in
                    y|Y)
                        if run_aws s3 rm "$file_uri"; then
                            echo "已删除远程文件：$file_uri"
                        else
                            echo "删除失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "已取消删除文件。"
                        pause
                        ;;
                esac
                ;;
            5)
                read -rp "请输入要删除的 Bucket 内目录/前缀（例如 backup/www，不能是空）： " REMOTE_DIR
                REMOTE_DIR="$(trim_slashes "$REMOTE_DIR")"
                if [[ -z "$REMOTE_DIR" ]]; then
                    echo "拒绝删除空目录或 bucket 根目录。"
                    pause
                    continue
                fi

                local rm_uri
                rm_uri="$(s3_uri_for "$REMOTE_DIR")"
                read -rp "确认删除整个目录 $rm_uri 吗？此操作不可恢复！(y/N)： " yn2
                case "$yn2" in
                    y|Y)
                        if run_aws s3 rm "$rm_uri" --recursive; then
                            echo "已删除远程目录：$rm_uri"
                        else
                            echo "删除失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "已取消删除目录操作。"
                        pause
                        ;;
                esac
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项。"
                pause
                ;;
        esac
    done
}

edit_s3_account() {
    echo "======================================="
    echo "修改账号"
    echo "======================================="

    CHOSEN_ACCOUNT_ID=""
    select_s3_account || { pause; return; }
    local ACCOUNT_ID="$CHOSEN_ACCOUNT_ID"
    local file="$ACCOUNTS_DIR/$ACCOUNT_ID.conf"

    load_s3_account "$ACCOUNT_ID" || { pause; return; }

    while true; do
        clear
        echo "======================================="
        echo "正在修改账号：$ACCOUNT_ID"
        echo "======================================="
        echo "[1] Bucket：$S3_BUCKET"
        echo "[2] Region：$S3_REGION"
        echo "[3] Endpoint URL：${S3_ENDPOINT_URL:-AWS默认}"
        echo "[4] 可选基础前缀：${S3_PREFIX:-/}"
        echo "[5] Access Key ID：$S3_ACCESS_KEY"
        echo "[6] Secret Access Key：已隐藏"
        echo "[7] 保存并退出"
        echo "[0] 不保存退出"
        echo

        read -rp "请选择要修改的项： " op
        case "$op" in
            1)
                local new_bucket
                if select_s3_bucket new_bucket "$S3_BUCKET"; then
                    S3_BUCKET="$new_bucket"
                    if [[ -n "$SELECTED_BUCKET_PREFIX" ]]; then
                        S3_PREFIX="$SELECTED_BUCKET_PREFIX"
                        echo "已把路径部分写入基础前缀：$S3_PREFIX"
                        sleep 1
                    fi
                fi
                ;;
            2)
                read -rp "输入新的 Region（回车取消）： " v
                [[ -n "$v" ]] && S3_REGION="$v"
                ;;
            3)
                read -rp "输入新的 Endpoint URL（输入空格并回车表示清空，直接回车取消）： " v
                if [[ "$v" == " " ]]; then
                    S3_ENDPOINT_URL=""
                elif [[ -n "$v" ]]; then
                    S3_ENDPOINT_URL="$v"
                fi
                ;;
            4)
                read -rp "输入新的可选基础前缀（输入空格并回车表示存储桶根目录）： " v
                if [[ "$v" == " " ]]; then
                    S3_PREFIX=""
                elif [[ -n "$v" ]]; then
                    S3_PREFIX="$(trim_slashes "$v")"
                fi
                ;;
            5)
                read -rp "输入新的 Access Key ID（回车取消）： " v
                [[ -n "$v" ]] && S3_ACCESS_KEY="$v"
                ;;
            6)
                read -rp "输入新的 Secret Access Key（回车取消）： " v
                [[ -n "$v" ]] && S3_SECRET_KEY="$v"
                ;;
            7)
                write_account_file "$file"
                echo "已保存：$file"
                pause
                return
                ;;
            0)
                echo "未保存，已退出。"
                pause
                return
                ;;
            *)
                echo "无效选项。"
                sleep 1
                ;;
        esac
    done
}

s3_account_menu() {
    while true; do
        clear
        echo "======================================="
        echo "账号管理"
        echo "======================================="
        echo "当前账号数量：$(get_s3_count)"
        echo
        echo "1) 新增账号"
        echo "2) 修改账号"
        echo "3) 查看账号列表"
        echo "4) 删除账号"
        echo "5) 使用账号浏览/下载/删除远程文件"
        echo "0) 返回主菜单"
        echo
        read -rp "请输入选项编号： " choice

        case "$choice" in
            1) add_s3_account ;;
            2) edit_s3_account ;;
            3) show_s3_accounts ;;
            4) delete_s3_account ;;
            5) browse_s3_with_account ;;
            0) break ;;
            *) echo "无效选项。"; pause ;;
        esac
    done
}

create_backup_archive() {
    local local_path="$1"
    local archive_path="$2"

    if [[ -d "$local_path" ]]; then
        local parent
        local base
        parent="$(dirname "$local_path")"
        base="$(basename "$local_path")"
        tar -czf "$archive_path" -C "$parent" "$base"
    else
        local parent
        local base
        parent="$(dirname "$local_path")"
        base="$(basename "$local_path")"
        tar -czf "$archive_path" -C "$parent" "$base"
    fi
}

prune_old_backups() {
    local remote_uri="$1"
    local backup_prefix="$2"
    local keep="$3"
    local files=()

    mapfile -t files < <(
        run_aws s3 ls "$remote_uri/" 2>/dev/null \
            | awk '{print $4}' \
            | while IFS= read -r name; do
                case "$name" in
                    "${backup_prefix}_"????????_??????.tar.gz) printf '%s\n' "$name" ;;
                esac
            done \
            | sort
    )

    local total="${#files[@]}"
    if (( total <= keep )); then
        echo "远程备份数量：$total，未超过保留数量 $keep，无需清理。"
        return 0
    fi

    local delete_count=$((total - keep))
    local i
    echo "远程备份数量：$total，将删除最旧的 $delete_count 份，只保留最新 $keep 份。"
    for ((i = 0; i < delete_count; i++)); do
        echo "删除旧备份：${files[$i]}"
        run_aws s3 rm "${remote_uri%/}/${files[$i]}" || return 1
    done
}

run_backup() {
    local ACCOUNT_ID="$1"
    local LOCAL_PATH="$2"
    local REMOTE_DIR="$3"

    load_s3_account "$ACCOUNT_ID" || return 1

    if [[ ! -e "$LOCAL_PATH" ]]; then
        echo "本地路径不存在：$LOCAL_PATH"
        return 1
    fi

    local remote_uri
    remote_uri="$(s3_uri_for "$REMOTE_DIR")"

    local base
    local safe_base
    local hash
    local timestamp
    local backup_prefix
    local archive_name
    local tmp_dir
    local archive_path

    base="$(basename "$LOCAL_PATH")"
    safe_base="$(safe_name "$base")"
    hash="$(path_hash "$LOCAL_PATH")"
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    backup_prefix="${safe_base}_${hash}"
    archive_name="${backup_prefix}_${timestamp}.tar.gz"
    tmp_dir="$(mktemp -d)"
    archive_path="$tmp_dir/$archive_name"

    echo "开始 S3 备份："
    echo "  账号：$ACCOUNT_ID"
    echo "  Bucket：$S3_BUCKET"
    echo "  本地路径：$LOCAL_PATH"
    echo "  S3 目标：$remote_uri"
    echo "  保留策略：只保留最新 $KEEP_COUNT 份"

    if ! create_backup_archive "$LOCAL_PATH" "$archive_path"; then
        echo "创建压缩包失败。"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo "正在上传：$archive_name"
    if ! run_aws s3 cp "$archive_path" "${remote_uri%/}/$archive_name"; then
        echo "上传失败，请检查 S3 账号、Bucket、Endpoint 和权限。"
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"

    if prune_old_backups "$remote_uri" "$backup_prefix" "$KEEP_COUNT"; then
        echo "备份完成。"
    else
        echo "备份已上传，但清理旧备份失败，请检查删除权限。"
        return 1
    fi
}

add_cron_job() {
    local CRON_EXPR="$1"
    local LOCAL_PATH="$2"
    local REMOTE_DIR="$3"
    local ACCOUNT_ID="$4"

    local script_q
    local account_q
    local local_q
    local remote_q
    script_q="$(shell_quote "$SCRIPT_PATH")"
    account_q="$(shell_quote "$ACCOUNT_ID")"
    local_q="$(shell_quote "$LOCAL_PATH")"
    remote_q="$(shell_quote "$REMOTE_DIR")"

    local CRON_LINE="$CRON_EXPR export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH\"; bash $script_q run $account_q $local_q $remote_q >/dev/null 2>&1 $TAG[$ACCOUNT_ID]"

    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

    echo "定时任务已添加："
    echo "   $CRON_LINE"
}

list_cron_jobs() {
    echo "======================================="
    echo "当前备份任务"
    echo "======================================="
    local lines
    lines=$(crontab -l 2>/dev/null | grep "$TAG" || true)

    if [[ -z "$lines" ]]; then
        echo "当前没有任何备份定时任务。"
        pause
        return
    fi

    local i=1
    declare -a JOBS
    while IFS= read -r line; do
        JOBS[$i]="$line"
        echo "[$i] $line"
        i=$((i + 1))
    done <<< "$lines"

    echo
    read -rp "是否选择其中一个任务立即执行一次？(y/N)： " run_now
    case "$run_now" in
        y|Y)
            read -rp "请输入任务编号： " choice
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${JOBS[$choice]}" ]]; then
                echo "输入编号无效。"
            else
                local target="${JOBS[$choice]}"
                local cmd_part
                cmd_part=$(echo "$target" | awk '{ $1=""; $2=""; $3=""; $4=""; $5=""; sub(/^ +/, ""); print }')
                echo "正在立即执行：$cmd_part"
                eval "$cmd_part"
            fi
            ;;
        *)
            ;;
    esac

    pause
}

delete_cron_job() {
    echo "======================================="
    echo "删除备份任务"
    echo "======================================="
    local lines
    lines=$(crontab -l 2>/dev/null | grep "$TAG" || true)

    if [[ -z "$lines" ]]; then
        echo "没有可删除的备份任务。"
        pause
        return
    fi

    local i=1
    declare -a JOBS
    while IFS= read -r line; do
        JOBS[$i]="$line"
        echo "[$i] $line"
        i=$((i + 1))
    done <<< "$lines"

    read -rp "请输入要删除的任务编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${JOBS[$choice]}" ]]; then
        echo "输入的编号无效。"
        pause
        return
    fi

    local target="${JOBS[$choice]}"

    crontab -l 2>/dev/null | grep -vF "$target" | crontab -

    echo "已删除任务：$target"
    pause
}

add_backup_job() {
    echo "======================================="
    echo "新建备份任务"
    echo "======================================="
    echo "说明：每次会打包成一个带时间戳的 .tar.gz 文件上传到 S3，并只保留最新 $KEEP_COUNT 份。"

    CHOSEN_ACCOUNT_ID=""
    select_s3_account || { pause; return; }
    local ACCOUNT_ID="$CHOSEN_ACCOUNT_ID"
    load_s3_account "$ACCOUNT_ID" || { pause; return; }

    echo
    echo "当前目标账号：$ACCOUNT_ID"
    echo "当前 Bucket：$S3_BUCKET"
    echo "基础前缀：${S3_PREFIX:-/}"

    while true; do
        read -rp "请输入要备份的本地文件/目录路径： " LOCAL_PATH

        if [[ ! -e "$LOCAL_PATH" ]]; then
            echo "路径不存在，请重新输入。"
            continue
        fi

        break
    done

    read -rp "请输入 Bucket 内目标目录/前缀（例如 /、backups/www）： " REMOTE_DIR

    if [[ -z "$REMOTE_DIR" ]]; then
        echo "Bucket 内目标目录/前缀不能为空。"
        pause
        return
    fi

    echo
    echo "请选择定时结构："
    echo "  1) 每天单次固定时间（例如凌晨 03:30）"
    echo "  2) 每小时的第 N 分钟（例如写 30）"
    echo "  3) 严格时间片间隔（仅限：1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30）"
    read -rp "请输入选项编号： " mode

    local CRON_EXPR=""

    case "$mode" in
        1)
            read -rp "每天几点执行？(0-23)： " H
            read -rp "每天几分执行？(0-59)： " M
            if ! [[ "$H" =~ ^[0-9]+$ ]] || ! [[ "$M" =~ ^[0-9]+$ ]] || ((H < 0 || H > 23)) || ((M < 0 || M > 59)); then
                echo "时间输入不合法，请遵循 24 小时制。"
                pause
                return
            fi
            CRON_EXPR="$M $H * * *"
            ;;
        2)
            read -rp "每小时的第几分钟准时触发？(0-59)： " M
            if ! [[ "$M" =~ ^[0-9]+$ ]] || ((M < 0 || M > 59)); then
                echo "分钟输入不合法。"
                pause
                return
            fi
            CRON_EXPR="$M * * * *"
            ;;
        3)
            read -rp "每隔多少分钟执行一次（必须输入上述提示的完美约数）： " N
            if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ ! " 1 2 3 4 5 6 10 12 15 20 30 " =~ " $N " ]]; then
                echo "输入的数值存在重叠执行风险，已拦截此配置。"
                pause
                return
            fi
            CRON_EXPR="*/$N * * * *"
            ;;
        *)
            echo "无效的选项。"
            pause
            return
            ;;
    esac

    add_cron_job "$CRON_EXPR" "$LOCAL_PATH" "$REMOTE_DIR" "$ACCOUNT_ID"

    echo
    read -rp "是否立即执行一次此备份任务？(Y/n)： " run_now
    if [[ -z "$run_now" || "$run_now" =~ ^[Yy]$ ]]; then
        run_backup "$ACCOUNT_ID" "$LOCAL_PATH" "$REMOTE_DIR"
    fi

    pause
}

uninstall_all() {
    echo "======================================="
    echo "卸载工具"
    echo "======================================="
    read -rp "确定要卸载吗？这会删除所有账号配置、备份任务和脚本本体。(y/N)： " ans
    case "$ans" in
        y|Y)
            if command_exists crontab; then
                local current
                current=$(crontab -l 2>/dev/null || true)
                if [[ -n "$current" ]]; then
                    echo "$current" | grep -v "$TAG" | crontab -
                fi
            fi

            rm -rf "$CONFIG_DIR"

            if [[ -f "$SCRIPT_PATH" ]]; then
                rm -f "$SCRIPT_PATH"
            fi

            echo "已卸载（已删除配置、任务和脚本本体）。"
            exit 0
            ;;
        *)
            echo "已取消卸载。"
            ;;
    esac
    pause
}

show_menu() {
    clear
    echo "======================================="
    echo "S3 备份工具（多账号版）"
    echo "======================================="
    echo
    local count
    count=$(get_s3_count)
    if (( count > 0 )); then
        echo "账号状态：已配置 $count 个"
    else
        echo "账号状态：未配置（请先添加账号）"
    fi
    echo "层级逻辑：账号 -> Bucket/存储桶；备份任务 -> Bucket 内目录/文件"
    echo "保留策略：每个备份任务只保留最新 $KEEP_COUNT 份"
    echo
    echo "1) 管理账号"
    echo "2) 新建备份任务"
    echo "3) 查看/立即执行备份任务"
    echo "4) 删除备份任务"
    echo "5) 卸载"
    echo "0) 退出"
    echo
    read -rp "请输入选项编号： " choice

    if ! is_s3_configured && [[ "$choice" != "1" && "$choice" != "5" && "$choice" != "0" ]]; then
        echo
        echo "当前尚未配置任何账号，请先进入“管理账号”添加。"
        pause
        return
    fi

    case "$choice" in
        1) s3_account_menu ;;
        2) add_backup_job ;;
        3) list_cron_jobs ;;
        4) delete_cron_job ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo "无效选项。"; pause ;;
    esac
}

if [[ "$1" == "run" ]]; then
    run_backup "$2" "$3" "$4"
    exit $?
fi

check_dependencies

while true; do
    show_menu
done

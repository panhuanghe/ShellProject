#!/usr/bin/env bash

# 交互式导出本地 Docker 镜像为 tar 文件。
# 自动过滤 Repository 或 Tag 为 <none> 的镜像。
#
# 用法：
#   ./export-docker-images.sh [输出目录]
# 示例：
#   ./export-docker-images.sh /data/docker-images

set -u

OUTPUT_DIR="${1:-./docker-image-tars}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "%b[INFO]%b %s\n" "$CYAN" "$NC" "$*"; }
success() { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$*"; }
warn()    { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$*"; }
error()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$*" >&2; }

check_environment() {
    if ! command -v docker >/dev/null 2>&1; then
        error "未找到 docker 命令，请先安装 Docker。"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "无法连接 Docker 服务，请确认 Docker daemon 已启动，并检查当前用户权限。"
        exit 1
    fi

    if ! mkdir -p "$OUTPUT_DIR"; then
        error "无法创建输出目录：$OUTPUT_DIR"
        exit 1
    fi
}

load_images() {
    IMAGE_REPOS=()
    IMAGE_TAGS=()
    IMAGE_IDS=()
    IMAGE_SIZES=()
    IMAGE_CREATED=()

    while IFS='|' read -r repository tag image_id size created; do
        [ -n "$image_id" ] || continue

        # 不在菜单中显示 <none> 镜像。
        if [ "$repository" = "<none>" ] || [ "$tag" = "<none>" ]; then
            continue
        fi

        IMAGE_REPOS+=("$repository")
        IMAGE_TAGS+=("$tag")
        IMAGE_IDS+=("$image_id")
        IMAGE_SIZES+=("$size")
        IMAGE_CREATED+=("$created")
    done < <(docker image ls --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}')
}

show_menu() {
    local count="${#IMAGE_IDS[@]}"
    local i image_name short_id

    printf '\n%b本地 Docker 镜像列表（已过滤 <none> 镜像）%b\n' "$CYAN" "$NC"
    printf '%-6s %-48s %-14s %-12s %s\n' "序号" "镜像" "IMAGE ID" "大小" "创建时间"
    printf '%-6s %-48s %-14s %-12s %s\n' "----" "----" "--------" "----" "--------"

    for ((i = 0; i < count; i++)); do
        image_name="${IMAGE_REPOS[$i]}:${IMAGE_TAGS[$i]}"
        short_id="${IMAGE_IDS[$i]#sha256:}"
        short_id="${short_id:0:12}"
        printf '%-6s %-48s %-14s %-12s %s\n' \
            "$((i + 1))" "$image_name" "$short_id" \
            "${IMAGE_SIZES[$i]}" "${IMAGE_CREATED[$i]}"
    done

    printf '\n'
    printf '输入镜像序号进行导出，支持多个序号，例如：1 3 5 或 1,3,5\n'
    printf '输入 %ba%b 导出全部镜像，输入 %br%b 刷新列表，输入 %bq%b 退出。\n' \
        "$YELLOW" "$NC" "$YELLOW" "$NC" "$YELLOW" "$NC"
}

make_tar_name() {
    local index="$1"
    local short_id="${IMAGE_IDS[$index]#sha256:}"
    local base

    short_id="${short_id:0:12}"
    base="${IMAGE_REPOS[$index]}_${IMAGE_TAGS[$index]}_${short_id}"
    base="$(printf '%s' "$base" | sed 's/[^a-zA-Z0-9._-]/_/g')"

    printf '%s/%s.tar' "${OUTPUT_DIR%/}" "$base"
}

export_image() {
    local index="$1"
    local reference output_file

    reference="${IMAGE_REPOS[$index]}:${IMAGE_TAGS[$index]}"
    output_file="$(make_tar_name "$index")"

    printf '\n'
    info "正在导出：$reference"
    info "目标文件：$output_file"

    if [ -e "$output_file" ]; then
        printf '文件已存在，是否覆盖？[y/N] '
        read -r overwrite
        case "$overwrite" in
            y|Y|yes|YES) ;;
            *)
                warn "已跳过：$reference"
                return 0
                ;;
        esac
    fi

    if docker image save -o "$output_file" "$reference"; then
        success "导出完成：$output_file"
    else
        error "导出失败：$reference"
        rm -f "$output_file"
        return 1
    fi
}

process_selection() {
    local selection="$1"
    local count="${#IMAGE_IDS[@]}"
    local token index
    local -a selected=()
    local seen_indexes=" "

    selection="${selection//,/ }"

    if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
        for ((index = 0; index < count; index++)); do
            selected+=("$index")
        done
    else
        for token in $selection; do
            if ! [[ "$token" =~ ^[0-9]+$ ]]; then
                error "无效输入：$token"
                return 1
            fi

            if ((token < 1 || token > count)); then
                error "序号超出范围：$token（有效范围为 1-$count）"
                return 1
            fi

            index=$((token - 1))
            if [[ "$seen_indexes" != *" $index "* ]]; then
                selected+=("$index")
                seen_indexes+="$index "
            fi
        done
    fi

    if [ "${#selected[@]}" -eq 0 ]; then
        error "没有选择任何镜像。"
        return 1
    fi

    for index in "${selected[@]}"; do
        export_image "$index" || true
    done
}

main() {
    check_environment

    while true; do
        load_images

        if [ "${#IMAGE_IDS[@]}" -eq 0 ]; then
            warn "当前没有带名称和标签的本地 Docker 镜像（<none> 镜像已自动过滤）。"
            exit 0
        fi

        show_menu
        printf '\n请选择：'
        read -r choice

        case "$choice" in
            q|Q)
                info "已退出。"
                exit 0
                ;;
            r|R)
                continue
                ;;
            '')
                warn "输入不能为空。"
                ;;
            *)
                process_selection "$choice"
                ;;
        esac
    done
}

main "$@"

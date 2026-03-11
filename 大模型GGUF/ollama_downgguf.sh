#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查 ollama 是否安装
if ! command -v ollama &> /dev/null; then
    echo -e "${RED}错误：未找到 ollama 命令。请先安装 ollama。${NC}"
    exit 1
fi

# 函数：显示菜单
show_menu() {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}      Ollama ModelScope 模型管理工具      ${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "1. 下载并重命名模型 (从 modelscope.cn)"
    echo "2. 退出"
    echo -e "${BLUE}-----------------------------------------${NC}"
}

# 函数：提取简洁的模型名称
# 逻辑：取最后一部分，去掉 :latest，尝试去掉 -GGUF 以便更整洁
get_clean_name() {
    local full_path="$1"
    # 如果包含标签（冒号），保留原始大小写并用冒号连接（例如: Qwen3.5-2B:Q3_K_M）
    if [[ "$full_path" == *:* ]]; then
        local tag="${full_path##*:}"
        local base="${full_path%%:*}"
        local filename=$(basename "${base}")
        local name_no_ext="$filename"
        # 如果文件名以 .gguf 结尾（任意大小写），去掉扩展名
        if [[ "${name_no_ext,,}" == *.gguf ]]; then
            name_no_ext="${name_no_ext%.*}"
        fi
        # 去掉尾部的 -GGUF 或 -gguf（有些 repo 名里会带这个后缀）
        local name_no_gguf="${name_no_ext%-GGUF}"
        name_no_gguf="${name_no_gguf%-gguf}"
        echo "${name_no_gguf}:${tag}"
    else
        local filename=$(basename "$full_path")
        local name_no_ext="$filename"
        if [[ "${name_no_ext,,}" == *.gguf ]]; then
            name_no_ext="${name_no_ext%.*}"
        fi
        local name_no_gguf="${name_no_ext%-GGUF}"
        name_no_gguf="${name_no_gguf%-gguf}"
        echo "${name_no_gguf}"
    fi
}

# 函数：执行下载和管理流程
run_process() {
    echo -e "${YELLOW}请输入 ModelScope 模型路径 (例如：unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF):${NC}"
    read -p "> " model_path

    if [ -z "$model_path" ]; then
        echo -e "${RED}输入不能为空！${NC}"
        read -p "按回车键返回菜单..."
        return
    fi

    # 构建完整地址
    full_model_addr="modelscope.cn/${model_path}"
    # 如果用户已在输入中指定了标签或文件名（包含冒号），则不要再追加 :latest
    if [[ "$model_path" == *:* ]]; then
        full_model_tag="${full_model_addr}"
    else
        full_model_tag="${full_model_addr}:latest"
    fi
    
    # 生成建议的新名称（自动推断），并允许用户覆盖
    suggested_name=$(get_clean_name "$model_path")
    read -p "建议重命名为: ${suggested_name}，要使用该名称吗？(Y/n 或 输入新名称): " name_choice
    if [[ -z "$name_choice" || "$name_choice" == "Y" || "$name_choice" == "y" ]]; then
        new_model_name="$suggested_name"
    else
        new_model_name="$name_choice"
    fi

    echo ""
    echo -e "${BLUE}[信息] 完整下载地址：${full_model_tag}${NC}"
    echo -e "${BLUE}[信息] 目标重命名：${new_model_name}${NC}"
    echo ""
    read -p "确认开始下载？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "操作已取消。"
        read -p "按回车键返回菜单..."
        return
    fi

    # 1. 运行并下载 (ollama run 会触发下载)
    echo -e "${GREEN}正在下载并运行模型... (这可能需要一段时间，取决于网速)${NC}"
    # 使用 timeout 或者让用户 Ctrl+C 退出运行状态，但为了脚本连续性，我们只让它启动一下然后中断？
    # 注意：ollama run 是交互式的。为了脚本自动化，我们通常只拉取 (pull)，但用户要求 run。
    # 策略：先 pull 确保下载完成，然后再 run 一次或者直接提示用户。
    # 修正策略：用户指令是 'ollama run' 用于下载。但在脚本中阻塞等待用户聊完天不合适。
    # 最佳实践：先用 'ollama pull' 下载，这样非交互式，下载完后重命名，最后提示用户去 run。
    
    echo -e "${YELLOW}正在后台拉取模型数据 (使用 ollama pull)...${NC}"
    if ! ollama pull "$full_model_tag"; then
        echo -e "${RED}下载失败！请检查网络或模型地址。${NC}"
        read -p "按回车键返回菜单..."
        return
    fi

    echo -e "${GREEN}下载完成！${NC}"

    # 2. 重命名 (cp)
    echo -e "${YELLOW}正在重命名模型...${NC}"
    if ollama cp "$full_model_tag" "$new_model_name"; then
        echo -e "${GREEN}成功将模型重命名为：${new_model_name}${NC}"
    else
        echo -e "${RED}重命名失败！${NC}"
        read -p "按回车键返回菜单..."
        return
    fi

    # 3. 询问是否删除原模型
    echo ""
    read -p "是否删除原始长名称模型 (${full_model_tag}) 以释放空间？(y/n): " clean_confirm
    if [[ "$clean_confirm" == "y" || "$clean_confirm" == "Y" ]]; then
        echo -e "${YELLOW}正在删除原模型...${NC}"
        if ollama rm "$full_model_tag"; then
            echo -e "${GREEN}原模型已删除。${NC}"
        else
            echo -e "${RED}删除原模型失败（可能已被占用或不存在）。${NC}"
        fi
    else
        echo "保留原模型。"
    fi

    echo ""
    echo -e "${BLUE}提示：你现在可以使用以下命令运行模型:${NC}"
    echo -e "   ${GREEN}ollama run ${new_model_name}${NC}"
    echo ""
    read -p "按回车键返回主菜单..."
}

# 主循环
while true; do
    show_menu
    read -p "请选择操作 [1-2]: " choice

    case $choice in
        1)
            run_process
            ;;
        2)
            echo "再见！"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请输入 1 或 2。${NC}"
            sleep 1
            ;;
    esac
done

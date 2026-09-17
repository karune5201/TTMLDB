#!/bin/sh
# 栈令 Git 工坊 v2 — 开源自由使用，请保留出处
# 针对原脚本常见失败点重写：权限文件、空提交、GitHub Token、分叉推送、菜单循环

GREEN="\033[1;32m"
RED="\033[1;31m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
DIM="\033[2m"
RESET="\033[0m"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

pause() {
  printf "\n${DIM}按回车返回菜单…${RESET}"
  read -r _
}

ok() { echo -e "${GREEN}>> $*${RESET}"; }
warn() { echo -e "${YELLOW}>> $*${RESET}"; }
err() { echo -e "${RED}>> $*${RESET}"; }
info() { echo -e "${BLUE}>> $*${RESET}"; }

need_git_repo() {
  if [ ! -d ".git" ]; then
    err "当前目录不是 Git 仓库。"
    echo "请把脚本放到仓库根目录再运行。"
    exit 1
  fi
}

current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

show_banner() {
  BRANCH=$(current_branch)
  REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
  USER_NAME=$(git config --get user.name 2>/dev/null || true)
  USER_EMAIL=$(git config --get user.email 2>/dev/null || true)

  echo "==========================================="
  echo "              栈令  Git 工坊 v2"
  echo "==========================================="
  echo -e "${GREEN}目录${RESET}   $SCRIPT_DIR"
  echo -e "${BLUE}分支${RESET}   $BRANCH"
  if [ -n "$REMOTE_URL" ]; then
    echo -e "${BLUE}远程${RESET}   $REMOTE_URL"
  else
    warn "未配置 remote.origin"
  fi
  if [ -n "$USER_NAME" ] && [ -n "$USER_EMAIL" ]; then
    echo -e "${DIM}身份   $USER_NAME <$USER_EMAIL>${RESET}"
  else
    warn "未配置 user.name / user.email，提交会被 Git 拒绝"
  fi

  git fetch --quiet origin 2>/dev/null || true
  AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)
  echo -e "${DIM}同步   领先 $AHEAD  / 落后 $BEHIND${RESET}"
  echo ""
}

explain_failure() {
  MSG=$1
  echo "$MSG" | grep -qi "Permission denied" && {
    err "文件权限被拒绝（常见：文件被占用、只读、云同步锁定）。"
    echo "  1. 关闭正在打开该文件的编辑器 / 播放器"
    echo "  2. 取消只读属性后重试"
    echo "  3. 脚本会自动跳过无法读取的文件，继续提交其余改动"
    return
  }
  echo "$MSG" | grep -qi "Password authentication is not supported\|Invalid username or token\|Authentication failed" && {
    err "GitHub 不再接受账号密码，必须用 Personal Access Token。"
    echo "  1. 打开 https://github.com/settings/tokens"
    echo "  2. 生成 classic token，勾选 repo"
    echo "  3. Username 填 GitHub 用户名，Password 处粘贴 Token"
    echo "  4. 不要把 Token 发给任何人，也不要提交进仓库"
    return
  }
  echo "$MSG" | grep -qi "Permission to .* denied\|HTTP.*403" && {
    err "Token 没有这个仓库的写权限（403）。"
    echo "  Classic Token 必须勾选 repo"
    echo "  Fine-grained Token 必须授权该仓库，Contents 设为 Read and write"
    return
  }
  echo "$MSG" | grep -qi "fetch first\|non-fast-forward\|rejected" && {
    err "远程有你本地没有的提交，不能直接推送。"
    echo "  已内置：先 git pull --rebase 再 push"
    echo "  若仍失败，请先选菜单 [1] 拉取，解决冲突后再推送"
    return
  }
}

safe_add() {
  ADD_LOG=$(mktemp 2>/dev/null || echo "/tmp/git-gong-add.log")
  if git add -A -- . 2>"$ADD_LOG"; then
    rm -f "$ADD_LOG"
    return 0
  fi

  warn "批量添加失败，改为逐个添加并跳过无法读取的文件…"
  FAILED=0
  git status --porcelain | while IFS= read -r line; do
    [ -z "$line" ] && continue
    path=${line#?? }
    case "$path" in
      *' -> '*) path=${path##* -> } ;;
    esac
    path=${path#\"}
    path=${path%\"}
    [ -z "$path" ] && continue
    if [ ! -e "$path" ] && [ ! -d "$path" ]; then
      git add -- "$path" 2>/dev/null || true
      continue
    fi
    if [ -e "$path" ] && [ ! -r "$path" ]; then
      warn "跳过无权限文件：$path"
      FAILED=1
      continue
    fi
    if ! git add -- "$path" 2>>"$ADD_LOG"; then
      warn "跳过无法索引：$path"
      FAILED=1
    fi
  done
  cat "$ADD_LOG" 2>/dev/null
  explain_failure "$(cat "$ADD_LOG" 2>/dev/null)"
  rm -f "$ADD_LOG"
  return 0
}

smart_push() {
  BRANCH=$(current_branch)
  info "检查与远程是否分叉…"
  git fetch origin "$BRANCH" 2>/dev/null || git fetch origin 2>/dev/null || true

  PUSH_OUT=$(git push origin "$BRANCH" 2>&1)
  PUSH_CODE=$?
  echo "$PUSH_OUT"
  if [ $PUSH_CODE -eq 0 ]; then
    ok "已推送到 origin/$BRANCH"
    return 0
  fi

  if echo "$PUSH_OUT" | grep -qi "fetch first\|non-fast-forward\|rejected"; then
    warn "远程有新提交，正在 rebase 后再推送…"
    if git pull --rebase origin "$BRANCH"; then
      PUSH_OUT=$(git push origin "$BRANCH" 2>&1)
      PUSH_CODE=$?
      echo "$PUSH_OUT"
      if [ $PUSH_CODE -eq 0 ]; then
        ok "rebase 后推送成功"
        return 0
      fi
    else
      err "rebase 出现冲突。请打开冲突文件修改后，选菜单 [8] 解决冲突。"
      echo "  或手动：git add <文件> && git rebase --continue"
      return 1
    fi
  fi

  explain_failure "$PUSH_OUT"
  err "推送失败。"
  return 1
}

commit_and_push() {
  echo -e "${GREEN}>> 提交本地修改并推送${RESET}"
  git status --short
  echo ""

  if [ -z "$(git status --porcelain)" ]; then
    BRANCH=$(current_branch)
    AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
    if [ "$AHEAD" != "0" ]; then
      warn "工作区干净，但本地领先远程 ${AHEAD} 个提交。改为直接推送。"
      smart_push
      return
    fi
    ok "没有可提交的修改，远程也已同步。"
    return
  fi

  safe_add
  if git diff --cached --quiet; then
    err "没有成功进入暂存区的文件（可能全被权限跳过，或改动已被还原）。"
    git status --short
    return
  fi

  echo ""
  git diff --cached --stat
  echo ""
  printf "请输入提交信息（留空则使用默认）： "
  read -r commit_message
  if [ -z "$commit_message" ]; then
    commit_message="Update by script"
  fi

  if git commit -m "$commit_message"; then
    smart_push
  else
    err "提交失败。请检查 user.name / user.email 是否已配置。"
  fi
}

push_only() {
  BRANCH=$(current_branch)
  AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)
  if [ "$AHEAD" = "0" ]; then
    ok "没有待推送的本地提交。"
    return
  fi
  info "本地领先 $AHEAD 个提交，开始推送…"
  smart_push
}

pull_latest() {
  BRANCH=$(current_branch)
  info "从远程拉取并 rebase 到当前分支 $BRANCH …"
  if git pull --rebase origin "$BRANCH"; then
    ok "仓库已更新为最新版本。"
  else
    err "拉取失败。可能是网络问题、冲突，或分支名不匹配。"
    echo "  冲突时：编辑文件 → 菜单 [8]"
  fi
}

switch_branch() {
  git branch -a
  printf "请输入目标分支名称: "
  read -r target_branch
  [ -z "$target_branch" ] && { err "未输入分支名"; return; }
  if git checkout "$target_branch"; then
    ok "已切换到分支: $target_branch"
  else
    err "切换失败。分支不存在，或有未提交修改。"
  fi
}

create_branch() {
  printf "请输入新分支名称: "
  read -r new_branch
  [ -z "$new_branch" ] && { err "未输入分支名"; return; }
  if git checkout -b "$new_branch"; then
    ok "已创建并切换到新分支: $new_branch"
  else
    err "创建失败。分支已存在，或有未提交修改。"
  fi
}

merge_branch() {
  git branch
  printf "请输入要合并进来的分支名称: "
  read -r merge_branch
  [ -z "$merge_branch" ] && { err "未输入分支名"; return; }
  if git merge "$merge_branch"; then
    ok "分支 $merge_branch 已合并到 $(current_branch)"
  else
    err "合并失败，可能存在冲突。"
    echo "  解决后选菜单 [8]"
  fi
}

resolve_conflicts() {
  git status
  echo ""
  if ! git diff --name-only --diff-filter=U | grep -q .; then
    ok "当前没有未解决的冲突。"
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
      warn "检测到未完成的 rebase。若冲突已解决："
      echo "  git add <文件> && git rebase --continue"
    fi
    return
  fi
  echo "未解决冲突的文件："
  git diff --name-only --diff-filter=U
  echo ""
  printf "请输入已解决的文件名（多个用空格，留空则添加全部冲突文件）: "
  read -r conflict_files
  if [ -z "$conflict_files" ]; then
    git diff --name-only --diff-filter=U | while IFS= read -r f; do
      git add -- "$f"
    done
  else
    for file in $conflict_files; do
      git add -- "$file"
    done
  fi
  if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
    git rebase --continue
  else
    git commit -m "Resolve merge conflicts"
  fi
  if [ $? -eq 0 ]; then
    ok "冲突已处理。"
  else
    err "仍未完成。请确认所有冲突标记已删除。"
  fi
}

tag_menu() {
  echo "标签子菜单："
  echo "  [1] 查看所有标签"
  echo "  [2] 创建新标签"
  echo "  [3] 删除本地标签"
  echo "  [4] 推送标签到远程"
  echo "  [5] 返回"
  printf "请输入选项 [1-5]: "
  read -r tag_choice
  case "$tag_choice" in
    1) git tag -l ;;
    2)
      printf "请输入标签名称: "
      read -r tag_name
      git tag "$tag_name" && ok "标签 $tag_name 创建成功。" || err "创建失败"
      ;;
    3)
      printf "请输入要删除的标签名称: "
      read -r tag_name
      git tag -d "$tag_name" && ok "已删除 $tag_name" || err "删除失败"
      ;;
    4)
      printf "请输入要推送的标签（留空推送全部）: "
      read -r tag_name
      if [ -z "$tag_name" ]; then
        git push origin --tags && ok "所有标签已推送"
      else
        git push origin "$tag_name" && ok "标签 $tag_name 已推送" || err "推送失败"
      fi
      ;;
    5) ;;
    *) err "输入无效" ;;
  esac
}

identity_help() {
  echo "当前身份："
  echo "  user.name  = $(git config --get user.name 2>/dev/null || echo '未设置')"
  echo "  user.email = $(git config --get user.email 2>/dev/null || echo '未设置')"
  echo ""
  printf "是否现在配置身份？[y/N]: "
  read -r ans
  case "$ans" in
    y|Y)
      printf "姓名: "
      read -r n
      printf "邮箱: "
      read -r e
      [ -n "$n" ] && git config user.name "$n"
      [ -n "$e" ] && git config user.email "$e"
      ok "已写入当前仓库配置（非 --global）"
      ;;
  esac
  echo ""
  echo "GitHub 推送必须用 Token，不能用登录密码。"
  echo "  生成：https://github.com/settings/tokens  （classic + repo）"
  echo "  推送时 Username = GitHub 用户名，Password = Token"
  echo "  不要把 Token 写进脚本、不要发给任何人"
  echo ""
  printf "可选：把 Token 写入当前仓库远程地址（仅本机，有泄露风险）[y/N]: "
  read -r ans
  case "$ans" in
    y|Y)
      printf "GitHub 用户名: "
      read -r ghuser
      printf "仓库 owner/name（如 karune5201/TTMLDB）: "
      read -r ghrepo
      printf "Token: "
      read -r ghtoken
      if [ -n "$ghuser" ] && [ -n "$ghrepo" ] && [ -n "$ghtoken" ]; then
        git remote set-url origin "https://${ghuser}:${ghtoken}@github.com/${ghrepo}.git"
        ok "已更新 origin。请勿把该地址提交到公开处。"
      else
        err "已取消（有空项）"
      fi
      ;;
  esac
}

need_git_repo

while true; do
  show_banner
  echo "功能菜单："
  echo "  [1] 从远程拉取最新（rebase）"
  echo "  [2] 提交本地修改并推送"
  echo "  [3] 仅推送已有提交"
  echo "  [4] 查看仓库状态"
  echo "  [5] 查看提交历史"
  echo "  [6] 查看未提交改动"
  echo "  [7] 切换分支"
  echo "  [8] 创建新分支"
  echo "  [9] 合并分支"
  echo "  [c] 解决冲突"
  echo "  [t] 标签管理"
  echo "  [i] 身份 / Token"
  echo "  [0] 退出"
  echo ""
  printf "请输入选项: "
  read -r choice

  case "$choice" in
    1) pull_latest; pause ;;
    2) commit_and_push; pause ;;
    3) push_only; pause ;;
    4) git status; pause ;;
    5)
      git log --pretty=format:"%C(yellow)%h %C(reset)%s %C(blue)(%an, %cr)%C(reset)" --graph -20
      echo ""
      pause
      ;;
    6)
      git diff --stat
      echo ""
      git diff
      pause
      ;;
    7) switch_branch; pause ;;
    8) create_branch; pause ;;
    9) merge_branch; pause ;;
    c|C|8x) resolve_conflicts; pause ;;
    t|T) tag_menu; pause ;;
    i|I) identity_help; pause ;;
    0)
      echo -e "${GREEN}感谢使用栈令，再见。${RESET}"
      exit 0
      ;;
    *)
      err "输入无效。"
      pause
      ;;
  esac
done

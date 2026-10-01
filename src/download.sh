get_latest_version() {
    case $1 in
    core)
        name=$is_core_name
        url="https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="$is_core_name 脚本"
        url="https://api.github.com/repos/$is_sh_repo/releases/latest?v=$RANDOM"
        ;;
    caddy)
        name="Caddy"
        url="https://api.github.com/repos/$is_caddy_repo/releases/latest?v=$RANDOM"
        ;;
    esac
    latest_ver=$(_wget -qO- $url | grep tag_name | grep -E -o 'v([0-9.]+)')
    # 仓库未发布 GitHub Release 时 (如直接 fork 后按分支开发), 上面会拿不到版本号.
    # 回退方案 (仅脚本): 读默认分支里 xray.sh 的 is_sh_ver, 并以 commit sha 标识构建.
    if [[ ! $latest_ver && $1 == sh ]]; then
        local raw_ver raw_sha
        raw_ver=$(_wget -qO- "https://raw.githubusercontent.com/$is_sh_repo/${is_sh_branch:-main}/xray.sh" | grep -m1 -E '^is_sh_ver=' | grep -E -o 'v[0-9.]+')
        raw_sha=$(_wget -qO- "https://api.github.com/repos/$is_sh_repo/commits/${is_sh_branch:-main}" | grep -m1 '"sha"' | cut -d'"' -f4)
        [[ $raw_ver ]] && latest_ver="$raw_ver+${raw_sha:0:7}"
    fi
    [[ ! $latest_ver ]] && {
        err "获取 ${name} 最新版本失败.\n备注: 若 $is_sh_repo 是私有/受限仓库, 请先 $(_green git release) 发布一个 Release."
    }
    unset name url
}
download() {
    latest_ver=$2
    [[ ! $latest_ver && $1 != 'dat' ]] && get_latest_version $1
    # tmp dir
    tmpdir=$(mktemp -u)
    [[ ! $tmpdir ]] && {
        tmpdir=/tmp/tmp-$RANDOM
    }
    mkdir -p $tmpdir
    case $1 in
    core)
        name=$is_core_name
        tmpfile=$tmpdir/$is_core.zip
        link="https://github.com/${is_core_repo}/releases/download/${latest_ver}/${is_core}-linux-${is_core_arch}.zip"
        download_file
        unzip -qo $tmpfile -d $is_core_dir/bin
        chmod +x $is_core_bin
        ;;
    sh)
        name="$is_core_name 脚本"
        tmpfile=$tmpdir/sh.zip
        # GitHub Release 包 (无前缀平铺); 无 Release 的仓库走 codeload 分支 zip (带 <repo>-<branch>/ 前缀)
        if [[ $(grep -E -o '\+[0-9a-f]{7}$' <<<"$latest_ver") ]]; then
            link="https://codeload.github.com/$is_sh_repo/zip/refs/heads/${is_sh_branch:-main}"
        else
            link="https://github.com/$is_sh_repo/releases/download/${latest_ver}/code.zip"
        fi
        download_file
        # 兼容两种 zip 结构: Release 平铺 / codeload 带前缀目录
        if unzip -l $tmpfile | grep -qE '[0-9a-zA-Z._-]+/xray\.sh'; then
            unzip -qo $tmpfile -d $tmpdir/un
            local prefix
            prefix=$(unzip -l $tmpfile | grep -E -o '[0-9a-zA-Z._-]+/xray\.sh' | head -1 | sed 's|/xray\.sh||')
            cp -rf $tmpdir/un/$prefix/* $is_sh_dir/
            rm -rf $tmpdir/un
        else
            unzip -qo $tmpfile -d $is_sh_dir
        fi
        [[ -e $is_sh_bin ]] && chmod +x $is_sh_bin
        ;;
    dat)
        name="geoip.dat"
        tmpfile=$tmpdir/geoip.dat
        link="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        download_file
        name="geosite.dat"
        tmpfile=$tmpdir/geosite.dat
        link="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
        download_file
        cp -f $tmpdir/*.dat $is_core_dir/bin/
        ;;
    caddy)
        name="Caddy"
        tmpfile=$tmpdir/caddy.tar.gz
        # https://github.com/caddyserver/caddy/releases/download/v2.6.4/caddy_2.6.4_linux_amd64.tar.gz
        link="https://github.com/${is_caddy_repo}/releases/download/${latest_ver}/caddy_${latest_ver:1}_linux_${caddy_arch}.tar.gz"
        download_file
        [[ ! $(type -P tar) ]] && {
            rm -rf $tmpdir
            err "请安装 tar"
        }
        tar zxf $tmpfile -C $tmpdir
        cp -f $tmpdir/caddy $is_caddy_bin
        chmod +x $is_caddy_bin
        ;;
    esac
    rm -rf $tmpdir
    unset latest_ver
}
download_file() {
    if ! _wget -t 5 -c $link -O $tmpfile; then
        rm -rf $tmpdir
        err "\n下载 ${name} 失败.\n"
    fi
}

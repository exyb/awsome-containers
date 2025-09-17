#!/bin/bash
# 用于生成OCI镜像增量包的脚本
# 参数: oldImage newImage
# 示例: ./oci_incre.sh harbor.asiainfo.com/dataflux/dataflux-auth:release-1.3.0_20250819234434 harbor.asiainfo.com/dataflux/dataflux-auth:release-1.3.0_20250819234436

# 依赖: skopeo, jq, tar
# 说明:
# 1. 拉取 oldImage 和 newImage 到本地 oci-layout 目录
# 2. 对比 blobs，找出 newImage 独有的 blobs
# 3. 获取 newImage 的 manifest、index.json
# 4. 打包增量内容为 tar 包

set -e


function get_tag() {
  # 从镜像名中提取 tag
  local image="$1"
  echo "$image" | awk -F: '{print $2}'
}
function get_default_osArch() {
  local ARCH="$(uname -m)";
  case "${ARCH}" in
  aarch64|arm64)
     _arch=arm64 ;
     ;;
  amd64|x86_64)
     _arch=amd64;
     ;;
  *)
    echo "Unsupported arch: ${ARCH}";
    return 1;
    ;;
  esac;
  echo "${_arch}"
}

function oci_incre() {

  local oldImage="$1"
  local newImage="$2"
  local osArch="${3:-linux/$(get_default_osArch)}"
  local os="${osArch%%/*}"
  local arch="${osArch##*/}"

  # 基础变量
  OCI_DIR="$(pwd)/${arch}/oci-images"
  INCRE_DIR="$(pwd)/${arch}/oci-temp"
  OUT_DIR="$(pwd)/${arch}/oci-incre"
  mkdir -p "$OCI_DIR"
  mkdir -p "$OUT_DIR"
  # 每次操作前清理 INCRE_DIR，保证干净
  rm -rf "$INCRE_DIR"
  mkdir -p "$INCRE_DIR"

  local oldTag=$(get_tag "$oldImage")
  local newTag=$(get_tag "$newImage")
  # 提取 repo 名（不含 registry 和 tag）
  local repo_name=$(echo "$newImage" | awk -F'/' '{print $(NF)}' | awk -F':' '{print $1}')
  local incre_tar="${repo_name}-${oldTag}-to-${newTag}-incre-${arch}.tar"

  # 拉取镜像到同一个 oci-layout 目录，自动复用 blobs, 拷贝所有arch
  skopeo copy --src-tls-verify=false --dest-tls-verify=false --format=oci "docker://${oldImage}" "oci:${OCI_DIR}"
  skopeo copy --src-tls-verify=false --dest-tls-verify=false --format=oci "docker://${newImage}" "oci:${OCI_DIR}"

  # blobs 目录（所有镜像的 blobs 都在同一个目录）
  local blobs="${OCI_DIR}/blobs/sha256"

  # 通过 skopeo 远程获取 index.json，找到指定 os/arch 的 manifest digest
  mkdir -p "${INCRE_DIR}/blobs/sha256"
  local old_index_json="${INCRE_DIR}/old_index.json"
  local new_index_json="${INCRE_DIR}/new_index.json"
  skopeo inspect --tls-verify=false --raw "docker://${oldImage}" > "$old_index_json"
  skopeo inspect --tls-verify=false  --raw "docker://${newImage}" > "$new_index_json"

  # 获取 manifest digest（os/arch 匹配） 简单匹配, 实际这里不需要select了, 已经筛选过了
  local old_manifest_digest=$(jq -r --arg os "$os" --arg arch "$arch" '.manifests[] | select(.platform.os==$os and .platform.architecture==$arch) | .digest' "$old_index_json" | head -n1 | sed 's/sha256://')
  local new_manifest_digest=$(jq -r --arg os "$os" --arg arch "$arch" '.manifests[] | select(.platform.os==$os and .platform.architecture==$arch) | .digest' "$new_index_json" | head -n1 | sed 's/sha256://')

  # 解析 manifest blob，获取 layers
  local old_manifest_blob="${blobs}/${old_manifest_digest}"
  local new_manifest_blob="${blobs}/${new_manifest_digest}"
  local old_layers=$(jq -r '.layers[].digest' "$old_manifest_blob" | sed 's/sha256://')
  local new_layers=$(jq -r '.layers[].digest' "$new_manifest_blob" | sed 's/sha256://')

  # 对比，找出 newImage 独有的 blobs
  for blob in $new_layers; do
    found=0
    for old_blob in $old_layers; do
      if [ "$blob" = "$old_blob" ]; then
        found=1
        break
      fi
    done
    if [ $found -eq 0 ]; then
      cp "$blobs/$blob" "${INCRE_DIR}/blobs/sha256/$blob"
    fi
  done

  # newImage 的 Config blob 必须始终拷贝到 oci-temp/blobs/sha256
  local config_digest=$(jq -r '.config.digest' "$new_manifest_blob" | sed 's/sha256://')
  if [ -f "$blobs/$config_digest" ]; then
    cp "$blobs/$config_digest" "${INCRE_DIR}/blobs/sha256/$config_digest"
  fi

  # newImage 的 LayersData 中 Size==32 的 blob 也必须全部拷贝
  local layers_data_all=$(skopeo inspect --tls-verify=false "docker://${newImage}" | jq -c '.LayersData')
  for link_digest in $(echo "$layers_data_all" | jq -r '.[] | select(.Size==32) | .Digest' | sed 's/sha256://'); do
    if [ -f "$blobs/$link_digest" ]; then
      cp "$blobs/$link_digest" "${INCRE_DIR}/blobs/sha256/$link_digest"
    fi
  done

  # 构造 docker 兼容 manifest.json
  # 获取 manifest 配置
  local manifest_config=$(jq -r '.config.digest' "$new_manifest_blob" | sed 's/sha256:/blobs\/sha256\//')
  # 获取 layers 路径
  local manifest_layers=$(jq -r '.layers[].digest' "$new_manifest_blob" | sed 's/sha256:/blobs\/sha256\//')
  # 获取 RepoTags
  local repo_tag="$newImage"
  # 获取 LayerSources（将 LayersData 数组转为 LayerSources 对象）
  local layers_data=$(skopeo inspect --tls-verify=false  "docker://${newImage}" | jq -c '.LayersData')
  local layer_sources=$(echo "$layers_data" | jq 'map({ (.Digest): { mediaType: .MIMEType, size: .Size, digest: .Digest } }) | add')
  # 构造 manifest.json
  jq -n --arg config "$manifest_config" \
        --argjson layers "$(printf '%s\n' $manifest_layers | jq -R . | jq -s .)" \
        --arg repo "$repo_tag" \
        --argjson layerSources "$layer_sources" \
        '[
          {
            Config: $config,
            RepoTags: [$repo],
            Layers: $layers,
            LayerSources: $layerSources
          }
        ]' > "${INCRE_DIR}/manifest.json"

  # 构造 index.json，仅保留目标平台 manifest，并补充注解
  jq --arg os "$os" --arg arch "$arch" --arg repo "$newImage" --arg tag "$newTag" '
    {
      schemaVersion,
      mediaType,
      manifests: [
        .manifests[]
        | select(.platform.os == $os and .platform.architecture == $arch)
        | . + {
            annotations: {
              "io.containerd.image.name": $repo,
              "org.opencontainers.image.ref.name": $tag
            }
          }
      ]
    }
  ' "$new_index_json" > "${INCRE_DIR}/index.json"

  test -f "${OCI_DIR}/oci-layout" && cp "${OCI_DIR}/oci-layout" "${INCRE_DIR}/oci-layout"

  # 打包增量内容，排除 old_*.json 和 new_*.json，去除 ./ 路径前缀，输出到 oci-incre 目录
  (cd "$INCRE_DIR" && tar --exclude='old_*.json' --exclude='new_*.json' -cvf "$OUT_DIR/$incre_tar" *)

  echo "增量包已生成: $OUT_DIR/$incre_tar"
}

# 主入口
if [ "$#" -le 2 ]; then
  echo "用法: $0 <oldImage> <newImage> [<osArch>]"
  exit 1
fi

oci_incre "$1" "$2" "$3"

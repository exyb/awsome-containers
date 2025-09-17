#!/bin/bash

export PS1='[${PWD##*/}]'
export PS4='+$LINENO: {${FUNCNAME[0]}} '

make_local_docker_incre_image() {
  local usage="/**
* @使用说明: make_local_docker_incre_image [-n] fromImage toImage
* @参数:
*   -n: 不下载, 依赖本地docker镜像
* @文件结构说明:
*   output    # 每个镜像 tag 目录保留4个增量镜像
*     xx-dev-20231110152049-20231111210309.tar
*   work      # 工作目录保存原始镜像
*     xx-dev-20231110152049.tar
*     xx-dev-20231111210309.tar
*   temp
*/"

  export ARCH="$(uname -m)";   case "${ARCH}" in    aarch64|arm64)   ARCH=arm64 ;     ;;  amd64|x86_64)   ARCH=amd64;  ;;  *)  echo "Unsupported arch: ${ARCH}";  return;   ;;   esac;
  local offline=false
  if [ "x$1" == "x-n" ];then
    offline=true
    shift
  fi
  local fromImage=$1
  local toImage=$2
  local arch=${3:-${ARCH}}
  if [ -z "${fromImage}" ]||[ -z "${toImage}" ];then
    echo "$usage"
    return
  fi
  local diffImageBaseDir=${BASE_DIR:-$PWD}/${arch}
  local diffImageOutputDir=${diffImageBaseDir}/output
  local diffImageWorkDir=${diffImageBaseDir}/work
  local diffImageTempDir=${diffImageBaseDir}/temp
  test ! -d ${diffImageOutputDir} && mkdir -p ${diffImageOutputDir}
  test ! -d ${diffImageWorkDir} && mkdir -p ${diffImageWorkDir}
  test ! -d ${diffImageTempDir} && mkdir -p ${diffImageTempDir}

  # 清理工作
  (
    cd $diffImageWorkDir
    ls -1 *tar 2>/dev/null | awk -F"-202............tar" '{print $1,$0}' 2>/dev/null | sort | awk '{n=img[$1]++;print n,$0}' | awk '$1>3{print $3}' |xargs /bin/rm -f
    cd -
    cd $diffImageOutputDir
    ls -1 *tar 2>/dev/null| awk -F"-202...........-202" '{print $1,$0}' 2>/dev/null | sort | awk '{n=img[$1]++;print n,$0}' | awk '$1>3{print $3}'  |xargs /bin/rm -f
    cd -
  )

  echo "===> Start to process with fromImage $fromImage <==="
  local fromImageName=$(echo ${fromImage##*/} | cut -d: -f1)
  local fromImageTag=$(echo ${fromImage##*/} | cut -d: -s -f2)
  local fromImageCreatedTime=$(echo ${fromImage##*/} |rev| cut -d_ -f1|rev)
  local fromImageFile=${fromImageName}-${fromImageTag}-${ARCH}.tar

  local needDownloadFromImage=false
  if ! $offline;then
    if [ ! -f $diffImageWorkDir/${fromImageFile} ];then
      needDownloadFromImage=true
    fi
    if [ -f $diffImageWorkDir/${fromImageFile}.md5sum ];then
      cd $diffImageWorkDir/;
      if ! cat ${fromImageFile}.md5sum|md5sum -c -;then
        needDownloadFromImage=true
      fi
      cd -
    fi

    if $needDownloadFromImage;then
      docker pull --platform=linux/${ARCH} ${fromImage}
      # fromImageCreatedTime=$(docker inspect ${fromImage} --format='{{index .Config.Labels "org.opencontainers.image.created"}}')
      # fromImageCreatedTimestamp=$(date --date="${fromImageCreatedTime}" +%Y%m%d%H%M%S)

      cd ${diffImageWorkDir}
      docker save ${fromImage} > $diffImageWorkDir/${fromImageFile}
      (cd $diffImageWorkDir/; md5sum ${fromImageFile} > ${fromImageFile}.md5sum)
      cd -
    fi
  elif [ ! -s $diffImageWorkDir/${fromImageFile} ];then
    cd ${diffImageWorkDir}
    docker save ${fromImage} > $diffImageWorkDir/${fromImageFile}
      (cd $diffImageWorkDir/; md5sum ${fromImageFile} > ${fromImageFile}.md5sum)
    cd -
  fi

  echo "===> Start to process with toImage $toImage <==="
  local toImageName=$(echo ${toImage##*/} | cut -d: -f1)
  local toImageTag=$(echo ${toImage##*/} | cut -d: -s -f2)
  local toImageCreatedTime=$(echo ${toImage##*/} |rev| cut -d_ -f1|rev)
  local toImageFile=${toImageName}-${toImageTag}-${ARCH}.tar

  if ! $offline;then
    if [ ! -f $diffImageWorkDir/${toImageFile}.md5sum ];then
      needDownloadtoImage=true
    else
      cd $diffImageWorkDir/;
      if ! cat ${toImageFile}.md5sum|md5sum -c -;then
        needDownloadtoImage=true
      fi
      cd -
    fi

    if $needDownloadtoImage;then
      docker pull --platform=linux/${ARCH} ${toImage}
      # toImageCreatedTime=$(docker inspect ${toImage} --format='{{index .Config.Labels "org.opencontainers.image.created"}}')
      # toImageCreatedTimestamp=$(date --date="${toImageCreatedTime}" +%Y%m%d%H%M%S)

      cd ${diffImageWorkDir}
      docker save ${toImage} > $diffImageWorkDir/${toImageFile}
      (cd $diffImageWorkDir/; md5sum ${toImageFile} > ${toImageFile}.md5sum)
      cd -
    fi
  elif [ ! -s $diffImageWorkDir/${toImageFile} ];then
    cd ${diffImageWorkDir}
    docker save ${toImage} > $diffImageWorkDir/${toImageFile}
    (cd $diffImageWorkDir/; md5sum ${toImageFile} > ${toImageFile}.md5sum)
    cd -
  fi

  local diffItems=$(comm -23 <(tar -tf $diffImageWorkDir/${toImageFile} | sort) <(tar -tf $diffImageWorkDir/${fromImageFile} | sort) | grep -v "/$")

  /bin/rm -fr ${diffImageTempDir}
  mkdir -p ${diffImageTempDir}/ || exit 1
  cd ${diffImageTempDir}/
  # 基础差异 + 额外差异
  tar -xf $diffImageWorkDir/${toImageFile} manifest.json repositories ${diffItems} $(tar -tvf $diffImageWorkDir/${toImageFile} |grep "layer.tar .*../.*layer.tar"|awk '{sub("../","",$NF);sub("/layer.tar","",$NF);print $NF}'|sort -u|xargs)

  tar -zcf ${diffImageOutputDir}/${fromImageName}-${fromImageTag}-${toImageTag}-${ARCH}.tar.gz *
  cd -

  echo "===> Finished to process with $fromImage to $toImage, output to ${diffImageOutputDir}/${fromImageName}-${fromImageTag}-${toImageTag}-${ARCH}.tar.gz<==="
}


make_local_docker_incre_image "$@"

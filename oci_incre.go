// oci_incre.go
// 用于生成OCI镜像增量包的Go实现，功能与 oci_incre.sh 保持一致
// 依赖：skopeo、jq、tar（通过os/exec调用），建议在Linux环境下运行
// 用法示例：go run oci_incre.go <oldImage> <newImage> [osArch]

package main

import (
	"archive/tar"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"context"

	"github.com/containers/image/v5/copy"
	"github.com/containers/image/v5/signature"
	"github.com/containers/image/v5/transports/alltransports"
	"github.com/containers/image/v5/types"
)

// contains 判断 slice 中是否包含某个字符串
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

type LayerData struct {
	MIMEType    string      `json:"MIMEType"`
	Digest      string      `json:"Digest"`
	Size        int64       `json:"Size"`
	Annotations interface{} `json:"Annotations"`
}

func getTag(image string) string {
	parts := strings.Split(image, ":")
	if len(parts) > 1 {
		return parts[1]
	}
	return ""
}

func getRepoName(image string) string {
	// harbor.asiainfo.com/dataflux/dataflux-auth:release-1.3.0_20250819180001
	parts := strings.Split(image, "/")
	last := parts[len(parts)-1]
	return strings.Split(last, ":")[0]
}

func runCmd(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	return nil, err
}

// runCmdSilent: 只返回命令输出，不打印到终端
func runCmdSilent(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	return cmd.Output()
}

// mustRunSilent: 只返回命令输出，出错时打印错误并退出
func mustRunSilent(name string, args ...string) []byte {
	out, err := runCmdSilent(name, args...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "命令失败: %s %v\n%s\n", name, args, string(out))
		os.Exit(1)
	}
	return out
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("用法: go run oci_incre.go <oldImage> <newImage> [osArch]")
		os.Exit(1)
	}
	oldImage := os.Args[1]
	newImage := os.Args[2]
	osArch := "linux/amd64"
	if len(os.Args) > 3 {
		osArch = os.Args[3]
	}
	osPart := strings.Split(osArch, "/")[0]
	archPart := strings.Split(osArch, "/")[1]

	OCI_DIR := filepath.Join(".", osArch, "oci-images")
	TEMP_DIR := filepath.Join(".", osArch, "oci-temp")
	OUT_DIR := filepath.Join(".", osArch, "oci-incre")
	os.MkdirAll(OCI_DIR, 0755)
	os.MkdirAll(OUT_DIR, 0755)
	os.RemoveAll(TEMP_DIR)
	os.MkdirAll(filepath.Join(TEMP_DIR, "blobs", "sha256"), 0755)

	oldTag := getTag(oldImage)
	newTag := getTag(newImage)
	repoName := getRepoName(newImage)
	increTar := fmt.Sprintf("%s-%s-to-%s-incre-%s.tar", repoName, oldTag, newTag, archPart)
	absOutDir, _ := filepath.Abs(OUT_DIR)
	absTempDir, _ := filepath.Abs(TEMP_DIR)
	increTarPath := filepath.Join(absOutDir, increTar)

	// 拉取镜像到 oci-layout（内嵌 skopeo copy 功能）
	copyImageToOCI("docker://"+oldImage, "oci:"+OCI_DIR)
	copyImageToOCI("docker://"+newImage, "oci:"+OCI_DIR)

	blobsDir := filepath.Join(OCI_DIR, "blobs", "sha256")

	// 获取 index.json（内嵌 skopeo inspect --raw 功能）
	oldIndexJson := filepath.Join(TEMP_DIR, "old_index.json")
	newIndexJson := filepath.Join(TEMP_DIR, "new_index.json")
	getRawManifest(oldImage, oldIndexJson)
	getRawManifest(newImage, newIndexJson)

	oldManifestDigest := getManifestDigest(oldIndexJson, osPart, archPart)
	newManifestDigest := getManifestDigest(newIndexJson, osPart, archPart)

	oldManifestBlob := filepath.Join(blobsDir, oldManifestDigest)
	newManifestBlob := filepath.Join(blobsDir, newManifestDigest)

	oldLayers := getLayers(oldManifestBlob)
	newLayers := getLayers(newManifestBlob)

	// 对比，找出 newImage 独有的 blobs
	for _, blob := range newLayers {
		if !contains(oldLayers, blob) {
			copyBlob(blobsDir, blob, filepath.Join(TEMP_DIR, "blobs", "sha256"))
		}
	}

	// newImage 的 Config blob 必须始终拷贝
	configDigest := getConfigDigest(newManifestBlob)
	copyBlob(blobsDir, configDigest, filepath.Join(TEMP_DIR, "blobs", "sha256"))

	// newImage 的 LayersData 中 Size==32 的 blob 也必须全部拷贝
	layersData := getLayersData(newImage)
	for _, ld := range layersData {
		if ld.Size == 32 {
			d := strings.TrimPrefix(ld.Digest, "sha256:")
			copyBlob(blobsDir, d, filepath.Join(TEMP_DIR, "blobs", "sha256"))
		}
	}

	// 构造 manifest.json
	manifestConfig := "blobs/sha256/" + configDigest
	manifestLayers := make([]string, 0)
	for _, l := range newLayers {
		manifestLayers = append(manifestLayers, "blobs/sha256/"+l)
	}
	layerSources := make(map[string]map[string]interface{})
	for _, ld := range layersData {
		layerSources[ld.Digest] = map[string]interface{}{
			"mediaType": ld.MIMEType,
			"size":      ld.Size,
			"digest":    ld.Digest,
		}
	}
	manifest := []map[string]interface{}{
		{
			"Config":       manifestConfig,
			"RepoTags":     []string{newImage},
			"Layers":       manifestLayers,
			"LayerSources": layerSources,
		},
	}
	writeJSON(filepath.Join(TEMP_DIR, "manifest.json"), manifest)

	// 构造 index.json
	index := getIndexJson(newIndexJson, osPart, archPart, newImage, newTag)
	writeJSON(filepath.Join(TEMP_DIR, "index.json"), index)

	// 拷贝 oci-layout
	copyFile(filepath.Join(OCI_DIR, "oci-layout"), filepath.Join(TEMP_DIR, "oci-layout"))

	// 使用 Go 标准库打包增量内容，排除 old_*.json 和 new_*.json
	outTar, err := os.Create(increTarPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "无法创建tar包: %v\n", err)
		os.Exit(1)
	}
	defer outTar.Close()
	tw := tar.NewWriter(outTar)
	defer tw.Close()

	// 递归遍历 absTempDir
	err = filepath.Walk(absTempDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relPath, _ := filepath.Rel(absTempDir, path)
		// 跳过根目录
		if relPath == "." {
			return nil
		}
		// 排除 old_*.json 和 new_*.json 文件
		if info.Mode().IsRegular() && (strings.HasPrefix(info.Name(), "old_") && strings.HasSuffix(info.Name(), ".json") ||
			strings.HasPrefix(info.Name(), "new_") && strings.HasSuffix(info.Name(), ".json")) {
			return nil
		}
		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		hdr.Name = relPath
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			_, err = io.Copy(tw, f)
			if err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "打包失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("增量包已生成: %s\n", increTarPath)
}

// 工具函数
func mustRun(name string, args ...string) []byte {
	out, err := runCmd(name, args...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "命令失败: %s %v\n%s\n", name, args, string(out))
		os.Exit(1)
	}
	return out
}

func getManifestDigest(indexJsonPath string, osName, arch string) string {
	data, _ := os.ReadFile(indexJsonPath)
	var idx struct {
		Manifests []struct {
			Digest   string `json:"digest"`
			Platform struct {
				OS           string `json:"os"`
				Architecture string `json:"architecture"`
			} `json:"platform"`
		} `json:"manifests"`
	}
	json.Unmarshal(data, &idx)
	for _, m := range idx.Manifests {
		if m.Platform.OS == osName && m.Platform.Architecture == arch {
			return strings.TrimPrefix(m.Digest, "sha256:")
		}
	}
	return ""
}

func getLayers(manifestBlob string) []string {
	data, _ := os.ReadFile(manifestBlob)
	var manifest struct {
		Layers []struct {
			Digest string `json:"digest"`
		} `json:"layers"`
	}
	json.Unmarshal(data, &manifest)
	layers := make([]string, 0)
	for _, l := range manifest.Layers {
		layers = append(layers, strings.TrimPrefix(l.Digest, "sha256:"))
	}
	return layers
}

func getConfigDigest(manifestBlob string) string {
	data, _ := os.ReadFile(manifestBlob)
	var manifest struct {
		Config struct {
			Digest string `json:"digest"`
		} `json:"config"`
	}
	json.Unmarshal(data, &manifest)
	return strings.TrimPrefix(manifest.Config.Digest, "sha256:")
}

func getLayersData(image string) []LayerData {
	out := mustRunSilent("skopeo", "inspect", "docker://"+image)
	var result struct {
		LayersData []LayerData `json:"LayersData"`
	}
	json.Unmarshal(out, &result)
	return result.LayersData
}

func copyBlob(blobsDir, digest, destDir string) {
	src := filepath.Join(blobsDir, digest)
	dst := filepath.Join(destDir, digest)
	if _, err := os.Stat(src); err == nil {
		in, _ := os.Open(src)
		out, _ := os.Create(dst)
		io.Copy(out, in)
		in.Close()
		out.Close()
	}
}

func writeJSON(path string, v interface{}) {
	data, _ := json.MarshalIndent(v, "", "  ")
	os.WriteFile(path, data, 0644)
}

func getIndexJson(indexJsonPath, osName, arch, repo, tag string) map[string]interface{} {
	data, _ := os.ReadFile(indexJsonPath)
	var idx struct {
		SchemaVersion int    `json:"schemaVersion"`
		MediaType     string `json:"mediaType"`
		Manifests     []struct {
			MediaType string `json:"mediaType"`
			Digest    string `json:"digest"`
			Size      int64  `json:"size"`
			Platform  struct {
				OS           string `json:"os"`
				Architecture string `json:"architecture"`
			} `json:"platform"`
		} `json:"manifests"`
	}
	json.Unmarshal(data, &idx)
	manifests := make([]map[string]interface{}, 0)
	for _, m := range idx.Manifests {
		if m.Platform.OS == osName && m.Platform.Architecture == arch {
			manifests = append(manifests, map[string]interface{}{
				"mediaType": m.MediaType,
				"digest":    m.Digest,
				"size":      m.Size,
				"annotations": map[string]interface{}{
					"io.containerd.image.name":          repo,
					"org.opencontainers.image.ref.name": tag,
				},
			})
		}
	}
	return map[string]interface{}{
		"schemaVersion": idx.SchemaVersion,
		"mediaType":     idx.MediaType,
		"manifests":     manifests,
	}
}

func copyFile(src, dst string) {
	in, err := os.Open(src)
	if err != nil {
		return
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return
	}
	defer out.Close()
	io.Copy(out, in)
}

// getRawManifest: 内嵌 skopeo inspect --raw 功能，拉取镜像 manifest 并写入文件
func getRawManifest(imageRef, outPath string) {
	ctx := context.Background()
	sys := &types.SystemContext{}
	ref, err := alltransports.ParseImageName("docker://" + imageRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "解析镜像名失败: %v\n", err)
		os.Exit(1)
	}
	imgSrc, err := ref.NewImageSource(ctx, sys)
	if err != nil {
		fmt.Fprintf(os.Stderr, "获取镜像源失败: %v\n", err)
		os.Exit(1)
	}
	defer imgSrc.Close()
	manifest, _, err := imgSrc.GetManifest(ctx, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "获取manifest失败: %v\n", err)
		os.Exit(1)
	}
	err = os.WriteFile(outPath, manifest, 0644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "写入manifest失败: %v\n", err)
		os.Exit(1)
	}
}

// copyImageToOCI: 内嵌 skopeo copy 功能，将 docker 镜像拷贝到本地 oci layout
func copyImageToOCI(srcRef, destRef string) {
	ctx := context.Background()
	sys := &types.SystemContext{}
	src, err := alltransports.ParseImageName(srcRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "解析源镜像失败: %v\n", err)
		os.Exit(1)
	}
	dest, err := alltransports.ParseImageName(destRef)
	if err != nil {
		fmt.Fprintf(os.Stderr, "解析目标镜像失败: %v\n", err)
		os.Exit(1)
	}
	// 创建默认策略
	policy, err := signature.DefaultPolicy()
	if err != nil {
		fmt.Fprintf(os.Stderr, "获取默认策略失败: %v\n", err)
		os.Exit(1)
	}
	policyCtx, err := signature.NewPolicyContext(policy)
	if err != nil {
		fmt.Fprintf(os.Stderr, "创建策略上下文失败: %v\n", err)
		os.Exit(1)
	}
	defer policyCtx.Destroy()
	_, err = copy.Image(ctx, policyCtx, dest, src, &copy.Options{
		SourceCtx:      sys,
		DestinationCtx: sys,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "镜像拷贝失败: %v\n", err)
		os.Exit(1)
	}
}

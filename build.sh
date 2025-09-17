export CGO_ENABLED=0
export GOOS=linux
export GOARCH=arm64

go build -ldflags "-s -w" -o gen-incre-image.arm64 oci_incre.go
upx gen-incre-image.arm64

export CGO_ENABLED=0
export GOOS=linux
export GOARCH=amd64

go build -ldflags "-s -w" -o gen-incre-image.amd64 oci_incre.go
upx gen-incre-image.amd64


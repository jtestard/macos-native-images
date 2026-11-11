# Build darwin/arm64 OCI images of third-party servers with the native
# BuildKit builder from github.com/jtestard/macos-container-runtime, and
# push them to Docker Hub. Every upstream source and model is pinned below.

NAMESPACE ?= jtstormz
BUILDER   ?= macnative-build
CMAKE_TOOLCHAIN ?= $(shell realpath "$$(brew --prefix cmake 2>/dev/null)" 2>/dev/null)

LLAMA_CPP_REF := ee0445c
WHISPER_REF   := v1.9.1
KOKORO_REF    := b4ef64b
UV_VERSION    := 0.13.4
NODE_VERSION  := 22.23.4
VOICE_VERSION := 0.1.1

LLAMA_IMAGE   := $(NAMESPACE)/llama-server:$(LLAMA_CPP_REF)-2
WHISPER_IMAGE := $(NAMESPACE)/whisper-server:$(WHISPER_REF)-base.en-2
KOKORO_IMAGE  := $(NAMESPACE)/kokoro:$(KOKORO_REF)-2
VOICE_AGENT_IMAGE := $(NAMESPACE)/voice-agent:$(VOICE_VERSION)
VOICE_WEB_IMAGE   := $(NAMESPACE)/voice-web:$(VOICE_VERSION)

B     := .build
CRANE := go run github.com/google/go-containerregistry/cmd/crane@v0.20.6
BUILDX = docker buildx build --builder $(BUILDER) --platform darwin/arm64 --progress plain

.PHONY: all llama-server whisper-server kokoro voice-agent voice-web push \
        push-llama-server push-whisper-server push-kokoro push-voice-agent \
        push-voice-web clean help
.DELETE_ON_ERROR:

help:
	@echo 'make all | llama-server | whisper-server | kokoro | voice-agent | voice-web'
	@echo '    build OCI tarballs in $(B)/'
	@echo 'make push | push-<image>'
	@echo 'Images: $(LLAMA_IMAGE) $(WHISPER_IMAGE) $(KOKORO_IMAGE)'
	@echo '        $(VOICE_AGENT_IMAGE) $(VOICE_WEB_IMAGE)'

all: llama-server whisper-server kokoro voice-agent voice-web
llama-server: $(B)/llama-server.tar
whisper-server: $(B)/whisper-server.tar
kokoro: $(B)/kokoro.tar
voice-agent: $(B)/voice-agent.tar
voice-web: $(B)/voice-web.tar

# Checks run inside build recipes only, so pushing an existing tarball does
# not need the builder.
CHECK_BUILDER = @docker buildx inspect --bootstrap $(BUILDER) >/dev/null 2>&1 || { \
	  echo 'Buildx builder $(BUILDER) is not running. Start the native BuildKit worker'; \
	  echo 'and register it as described in the macos-container-runtime README.'; exit 1; }
CHECK_CMAKE = @test -x "$(CMAKE_TOOLCHAIN)/bin/cmake" || { \
	  echo 'Set CMAKE_TOOLCHAIN to a CMake.app/Contents directory or a Homebrew CMake keg'; \
	  echo '(brew install cmake sets it automatically).'; exit 1; }

# ---- llama.cpp server (model-free) -------------------------------------------

$(B)/src/llama.cpp:
	git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git $@.tmp
	git -C $@.tmp checkout -q $(LLAMA_CPP_REF)
	printf '.git/\n/build/\n/models/\n.github/\ntools/ui/node_modules/\n' > $@.tmp/.dockerignore
	mv $@.tmp $@

$(B)/llama-server.tar: images/llama-server/Dockerfile | $(B)/src/llama.cpp
	$(CHECK_BUILDER)
	$(CHECK_CMAKE)
	$(BUILDX) --build-context llama-source=$(CURDIR)/$(B)/src/llama.cpp \
	  --build-context cmake-toolchain=$(CMAKE_TOOLCHAIN) \
	  --output type=oci,dest=$@ images/llama-server

# ---- whisper.cpp server with the English base model --------------------------

$(B)/src/whisper.cpp:
	git clone --depth 1 --branch $(WHISPER_REF) https://github.com/ggml-org/whisper.cpp.git $@.tmp
	printf '.git/\n/build/\n/models/\n' > $@.tmp/.dockerignore
	mv $@.tmp $@

$(B)/whisper-model/ggml-base.en.bin:
	mkdir -p $(@D)
	curl -fL -o $@ https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

$(B)/whisper-server.tar: images/whisper-server/Dockerfile $(B)/whisper-model/ggml-base.en.bin | $(B)/src/whisper.cpp
	$(CHECK_BUILDER)
	$(CHECK_CMAKE)
	$(BUILDX) --build-context whisper-source=$(CURDIR)/$(B)/src/whisper.cpp \
	  --build-context whisper-model=$(CURDIR)/$(B)/whisper-model \
	  --build-context cmake-toolchain=$(CMAKE_TOOLCHAIN) \
	  --output type=oci,dest=$@ images/whisper-server

# ---- Kokoro-FastAPI on Metal (MPS) with Kokoro-82M weights -------------------

$(B)/src/Kokoro-FastAPI:
	git clone --filter=blob:none https://github.com/remsky/Kokoro-FastAPI.git $@.tmp
	git -C $@.tmp checkout -q $(KOKORO_REF)
	printf '.git/\n.venv/\nnode_modules/\n*.pth\n' > $@.tmp/.dockerignore
	mv $@.tmp $@

$(B)/kokoro-weights/kokoro-v1_0.pth:
	mkdir -p $(@D)
	curl -fL -o $@ https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/kokoro-v1_0.pth

$(B)/uv/uv:
	mkdir -p $(@D)
	curl -fL https://github.com/astral-sh/uv/releases/download/$(UV_VERSION)/uv-aarch64-apple-darwin.tar.gz \
	  | tar -xz -C $(@D) --strip-components 1 uv-aarch64-apple-darwin/uv

$(B)/launcher/launch: launcher/main.go launcher/go.mod
	mkdir -p $(@D)
	GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go -C launcher build -trimpath -o $(CURDIR)/$@ .

$(B)/kokoro.tar: images/kokoro/Dockerfile images/kokoro/launch.json $(B)/kokoro-weights/kokoro-v1_0.pth $(B)/uv/uv $(B)/launcher/launch | $(B)/src/Kokoro-FastAPI
	$(CHECK_BUILDER)
	$(BUILDX) --build-context uv-toolchain=$(CURDIR)/$(B)/uv \
	  --build-context kokoro-source=$(CURDIR)/$(B)/src/Kokoro-FastAPI \
	  --build-context kokoro-weights=$(CURDIR)/$(B)/kokoro-weights \
	  --build-context launcher=$(CURDIR)/$(B)/launcher \
	  --output type=oci,dest=$@ images/kokoro

# ---- voice agent and web client (this repository's own code) ----------------

$(B)/node/bin/node:
	mkdir -p $(B)/node
	curl -fL https://nodejs.org/dist/v$(NODE_VERSION)/node-v$(NODE_VERSION)-darwin-arm64.tar.gz \
	  | tar -xz -C $(B)/node --strip-components 1

$(B)/voice-agent.tar: images/voice-agent/Dockerfile images/voice-agent/launch.json \
    voice/agent/agent.js voice/agent/package.json voice/agent/package-lock.json \
    $(B)/node/bin/node $(B)/launcher/launch
	$(CHECK_BUILDER)
	$(BUILDX) --build-context node-toolchain=$(CURDIR)/$(B)/node \
	  --build-context agent-source=$(CURDIR)/voice/agent \
	  --build-context launcher=$(CURDIR)/$(B)/launcher \
	  --output type=oci,dest=$@ images/voice-agent

# A Linux image for the Kind cluster, built by Docker Desktop.
$(B)/voice-web.tar: images/voice-web/Dockerfile voice/web/main.go voice/web/index.html voice/web/go.mod
	docker --context desktop-linux buildx build --platform linux/arm64 --progress plain \
	  -f images/voice-web/Dockerfile --output type=oci,dest=$@,name=$(VOICE_WEB_IMAGE) voice/web

# ---- publish ----------------------------------------------------------------

# crane pushes the OCI index as built, keeping its darwin/arm64 platform entry.
# It uses your Docker credentials; run `docker login` as the $(NAMESPACE) account.
define push_tar
	rm -rf $(B)/push/$(1) && mkdir -p $(B)/push/$(1) && tar -xf $(B)/$(1).tar -C $(B)/push/$(1)
	$(CRANE) push --index $(B)/push/$(1) $(2)
	rm -rf $(B)/push/$(1)
endef

push: push-llama-server push-whisper-server push-kokoro push-voice-agent push-voice-web
push-llama-server: $(B)/llama-server.tar
	$(call push_tar,llama-server,$(LLAMA_IMAGE))
push-whisper-server: $(B)/whisper-server.tar
	$(call push_tar,whisper-server,$(WHISPER_IMAGE))
push-kokoro: $(B)/kokoro.tar
	$(call push_tar,kokoro,$(KOKORO_IMAGE))
push-voice-agent: $(B)/voice-agent.tar
	$(call push_tar,voice-agent,$(VOICE_AGENT_IMAGE))
push-voice-web: $(B)/voice-web.tar
	$(call push_tar,voice-web,$(VOICE_WEB_IMAGE))

clean:
	rm -rf $(B)

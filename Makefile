# helper function to turn a string into lower case
lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$1))))))))))))))))))))))))))
ifneq ($(CI_REGISTRY),)
IMAGE_PATH?=$(call lc,$(CI_REGISTRY)/$(CI_PROJECT_NAMESPACE)/)
endif

ifneq ($(CI_PIPELINE_ID),)
PNS:=$(CI_PIPELINE_ID)
else
PNS:=$(shell whoami | sed 's/[^[:alnum:]._-]\+/_/g')
endif

# If we are running in CI and on the default branch (like 'main' or 'master'),
# disable the build cache for docker builds. We do this with ?= operator in
# make so we only set DOCKER_BUILD_CACHE_ARG if it is not already set, this
# makes it possible to still use the cache if explicitly set through
# environment variables in CI.
ifneq ($(CI),)
ifeq ($(CI_COMMIT_REF_NAME),$(CI_DEFAULT_BRANCH))
DOCKER_BUILD_CACHE_ARG?=--no-cache
endif
endif

DOCKER_TAG?=$(PNS)

export DOCKER_BUILDKIT=1

.PHONY: clone-deps build test tag-release push-release push test

clone-or-update: BRANCH?=devel
clone-or-update: DIR:=$(basename $(lastword $(subst /, ,$(REPOSITORY))))
clone-or-update:
	@mkdir -p src
	if ! git clone -b $(BRANCH) $(REPOSITORY) src/$(DIR); then \
		cd src/$(DIR); \
		git pull; \
	fi

clone-deps:
	$(MAKE) clone-or-update REPOSITORY=https://github.com/CESNET/libyang.git
	$(MAKE) clone-or-update REPOSITORY=https://github.com/sysrepo/sysrepo.git
	$(MAKE) clone-or-update REPOSITORY=http://git.libssh.org/projects/libssh.git BRANCH=stable-0.9
	$(MAKE) clone-or-update REPOSITORY=https://github.com/CESNET/libnetconf2.git
	$(MAKE) clone-or-update REPOSITORY=https://github.com/CESNET/netopeer2.git

build:
# We explicitly build the first 'build-tools-source' stage (where the
# dependencies are installed and source code is pulled), which allows us to
# control caching of it through the DOCKER_BUILD_CACHE_ARG.
	docker build --target build-tools-source $(DOCKER_BUILD_CACHE_ARG) .
	docker build --target notconf-release -t $(IMAGE_PATH)notconf:$(DOCKER_TAG) --build-arg BUILD_TYPE=Release .
	docker build --target notconf-debug -t $(IMAGE_PATH)notconf:$(DOCKER_TAG)-debug --build-arg BUILD_TYPE=Debug .

tag-release:
	docker tag $(IMAGE_PATH)notconf:$(DOCKER_TAG) $(IMAGE_PATH)notconf:latest
	docker tag $(IMAGE_PATH)notconf:$(DOCKER_TAG)-debug $(IMAGE_PATH)notconf:debug

push-release:
	docker push $(IMAGE_PATH)notconf:debug
	docker push $(IMAGE_PATH)notconf:latest

push:
	docker push $(IMAGE_PATH)notconf:$(DOCKER_TAG)
	docker push $(IMAGE_PATH)notconf:$(DOCKER_TAG)-debug

test: export CNT_PREFIX=test-notconf-$(PNS)
test:
	-docker rm -f $(CNT_PREFIX)
# Usually we would start the notconf container with the desired YANG module
# (located on host) mounted to /yang-modules (in container). When the test
# itself is executed in a (CI runner) container bind mounting a path won't work
# because the path does not exist on the host, only in the test container. As a
# workaround we first create the container and then copy the YANG module to the
# target location.
#	docker run -d --name $(CNT_PREFIX) -v $$(pwd)/test/test.yang:/yang-modules/test.yang $(IMAGE_PATH)notconf:$(DOCKER_TAG)
	docker create --name $(CNT_PREFIX) $(IMAGE_PATH)notconf:$(DOCKER_TAG)
	docker cp test/test.yang $(CNT_PREFIX):/yang-modules/
	docker start $(CNT_PREFIX)
	$(MAKE) wait-healthy
	netconf-console2 --host $$(docker inspect $(CNT_PREFIX) --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}') --port 830 --edit-config test/test.xml
	netconf-console2 --host $$(docker inspect $(CNT_PREFIX) --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}') --port 830 --get-config -x /bob/bert | grep Robert
	$(MAKE) save-logs
	$(MAKE) test-stop

test-stop: CNT_PREFIX?=test-notconf
test-stop:
	docker ps -aqf name=$(CNT_PREFIX) | xargs --no-run-if-empty docker rm -f

save-logs: CNT_PREFIX?=test-notconf
save-logs:
	mkdir -p docker-logs
	@for c in $$(docker ps -af name=$(CNT_PREFIX) --format '{{.Names}}'); do \
		echo "== Collecting logs from $${c}"; \
		docker logs $${c} > docker-logs/$${c} 2>&1; \
	done

SHELL=/bin/bash

wait-healthy:
	@echo "Waiting (up to 900 seconds) for containers with prefix $(CNT_PREFIX) to become healthy"
	@OLD_COUNT=0; for I in $$(seq 1 900); do \
		COUNT=$$(docker ps -f name=$(CNT_PREFIX) | egrep "(unhealthy|health: starting)" | wc -l); \
		if [ $$COUNT -gt 0 ]; then  \
			if [ $$OLD_COUNT -ne $$COUNT ];\
			then \
				echo -e "\e[31m===  $${SECONDS}s elapsed - Found unhealthy/starting ($${COUNT}) containers";\
				docker ps -f name=$(CNT_PREFIX) | egrep "(unhealthy|health: starting)" | awk '{ print $$(NF) }';\
				echo -e "Checking again every 1 second, no more messages until changes detected\\e[0m"; \
			fi;\
			sleep 1; \
			OLD_COUNT=$$COUNT;\
			continue; \
		else \
			echo -e "\e[32m=== $${SECONDS}s elapsed - Did not find any unhealthy containers, all is good.\e[0m"; \
			exit 0; \
		fi ;\
	done; \
	echo -e "\e[31m===  $${SECONDS}s elapsed - Found unhealthy/starting ($${COUNT}) containers";\
	docker ps -f name=$(CNT_PREFIX) | egrep "(unhealthy|health: starting)" | awk '{ print $$(NF) }';\
	echo -e "\e[0m"; \
	exit 1

.PHONY: checkout-yang build-yang

checkout-yang:
	git clone --recurse-submodules -4 git@github.com:yangmodels/yang.git

build-yang: SHELL=/bin/bash
build-yang: YANG_TAG=foo
build-yang:
	@if [ -z "$(YANG_PATH)" ]; then echo "The YANG_PATH variable must be set"; exit 1; fi
	rm -rf tmp
	mkdir -p tmp
	@for fixup in `find fixups -type f -printf "%d %P\n" | sort -n -r | awk '{ print $$2; }'`; do \
		if [[ "$(YANG_PATH)" =~ ^$$(dirname $${fixup}).* ]]; then \
			fixups/$$fixup $(YANG_PATH) tmp; \
		fi \
	done
	ls tmp/*.yang || cp $(YANG_PATH) tmp
	docker build -f Dockerfile.yang -t $(IMAGE_PATH)notconf:$(YANG_TAG) .

test-yang: YANG_TAG=foo
test-yang:
	-docker rm -f test-yang-$(PNS)
	docker run -d --name test-yang-$(PNS) $(IMAGE_PATH)notconf:$(YANG_TAG)

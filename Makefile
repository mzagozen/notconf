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

.PHONY: clone-deps build test tag-release push-release push test push-composed-notconf

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

tag-release-composed-notconf: composed-notconf.txt
	for tag in $$(uniq $<); do release_tag=$$(echo $${tag} | sed 's/-$(PNS)$$//'); docker tag $${tag} $${release_tag}; done

push-release-composed-notconf: composed-notconf.txt
	for release_tag in $$(sed 's/-$(PNS)$$//g' $< | uniq); do docker push $${release_tag}; done

test:
	$(MAKE) test-notconf-mount
	$(MAKE) clone-yangmodels
	> composed-notconf.txt
	$(MAKE) test-compose-yang YANG_PATH=test
	$(MAKE) test-compose-yang YANG_PATH=yang/vendor/nokia/7x50_YangModels/latest_sros_21.10
	$(MAKE) test-compose-yang YANG_PATH=yang/vendor/juniper/21.1/21.1R1/junos

# test-notconf-mount: start a notconf:latest container with the test YANG
# modules mounted to /yang-modules in the container. All YANG modules and XML
# init files in the directory are installed into sysrepo automatically at
# container startup.
test-notconf-mount: CNT_PREFIX=test-notconf-mount-$(PNS)
test-notconf-mount:
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

.PHONY: clone-yangmodels compose-notconf-yang test-compose-yang test-composed-notconf-yang

# clone-yangmodels: clones and checks out the yangmodels/yang repository
# including submodules
clone-yangmodels:
	if [ ! -d yang ]; then \
		git clone --depth 1 --recurse-submodules=vendor --shallow-submodules https://github.com/yangmodels/yang.git; \
	else \
		cd yang; \
		git pull && git submodule update --recursive --recommend-shallow; \
	fi

# Set up COMPOSE_IMAGE_* variables by examining the provided YANG_PATH variable.
# The conditions below knows how to extract the platform and version from the
# yangmodules/yang paths. If none match, default to just using YANG_PATH.
EXPLODED_YANG_PATH=$(subst /, ,$(YANG_PATH))
ifneq (,$(findstring latest_sros, $(YANG_PATH)))
	COMPOSE_IMAGE_NAME?=sros
	COMPOSE_IMAGE_TAG?=$(subst latest_sros_,,$(filter latest_sros%,$(EXPLODED_YANG_PATH)))
else ifneq (,$(findstring junos, $(YANG_PATH)))
	WC=$(words $(EXPLODED_YANG_PATH))
	COMPOSE_IMAGE_NAME?=$(lastword $(EXPLODED_YANG_PATH))
	COMPOSE_IMAGE_TAG?=$(word $(shell echo $$(( $(WC) - 1 ))), $(EXPLODED_YANG_PATH))
else
	COMPOSE_IMAGE_NAME?=$(subst /,_,$(patsubst %/,%,$(YANG_PATH)))
	COMPOSE_IMAGE_TAG?=latest
endif

# compose-notconf-yang: build a docker image with notconf:base with the given
# YANG modules already installed. Provide the path to the modules (and init
# XMLs) with the YANG_PATH variable.
compose-notconf-yang: COMPOSE_PATH=build/$(COMPOSE_IMAGE_NAME)/$(COMPOSE_IMAGE_TAG)
compose-notconf-yang:
	@if [ -z "$(YANG_PATH)" ]; then echo "The YANG_PATH variable must be set"; exit 1; fi
	rm -rf $(COMPOSE_PATH)
	mkdir -p $(COMPOSE_PATH)
	@set -e; \
	for fixup in `find fixups -type f -name Makefile -printf "%d %P\n" | sort -n -r | awk '{ print $$2; }'`; do \
		if [[ "$(YANG_PATH)" =~ ^$$(dirname $${fixup}).* ]]; then \
			echo "Executing fixups/$${fixup}"; \
			make -f fixups/$$fixup -j YANG_PATH=$(YANG_PATH) COMPOSE_PATH=$(COMPOSE_PATH); \
		fi \
	done
	if ! ls $(COMPOSE_PATH)/*.yang > /dev/null 2>&1; then \
		echo "Copying files directly from $(YANG_PATH) without fixups"; \
		find $(YANG_PATH) -maxdepth 1 -type f -exec cp -t $(COMPOSE_PATH) {} +; \
	fi
	docker build -f Dockerfile.yang -t $(IMAGE_PATH)notconf-$(COMPOSE_IMAGE_NAME):$(COMPOSE_IMAGE_TAG)-$(PNS) --build-arg COMPOSE_PATH=$(COMPOSE_PATH) --build-arg IMAGE_PATH=$(IMAGE_PATH) --build-arg DOCKER_TAG=$(DOCKER_TAG) $(DOCKER_BUILD_CACHE_ARG) .
	echo $(IMAGE_PATH)notconf-$(COMPOSE_IMAGE_NAME):$(COMPOSE_IMAGE_TAG)-$(PNS) >> composed-notconf.txt

test-compose-yang: export YANG_PATH=$(YANG_PATH)
test-compose-yang: compose-notconf-yang
	$(MAKE) test-composed-notconf-yang

test-composed-notconf-yang: CNT_PREFIX=test-yang-$(COMPOSE_IMAGE_NAME)-$(COMPOSE_IMAGE_TAG)-$(PNS)
test-composed-notconf-yang:
	-docker rm -f $(CNT_PREFIX)
	docker run -d --name $(CNT_PREFIX) $(IMAGE_PATH)notconf-$(COMPOSE_IMAGE_NAME):$(COMPOSE_IMAGE_TAG)-$(PNS)
	$(MAKE) wait-healthy
	netconf-console2 --host $$(docker inspect $(CNT_PREFIX) --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}') --port 830 --hello | grep nc:capability
	make test-stop

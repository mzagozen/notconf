YANGS=$(wildcard $(YANG_PATH)/conf/*.yang)
YANGS+=$(wildcard $(YANG_PATH)/../common/*.yang)

all: $(YANGS)
	cp $^ $(COMPOSE_PATH)

all: $(patsubst $(YANG_PATH)/conf/%.yang,$(COMPOSE_PATH)/%.yang,$(wildcard $(YANG_PATH)/conf/*.yang))
all: $(patsubst $(YANG_PATH)/../common/%.yang,$(COMPOSE_PATH)/%.yang,$(wildcard $(YANG_PATH)/../common/*.yang))

vpath %.yang $(YANG_PATH)/conf
vpath %.yang $(YANG_PATH)/../common

$(COMPOSE_PATH)/%.yang: %.yang
# Use single quotes instead of double quotes for [pattern "\*"] statements
# (matching literal *). All the validators on
# https://yangvalidator.com/yangvalidator complain about double quotes so it
# must be something ...
	sed "s:\"\\\\\*\":'\\\\\*':g" $< > $@

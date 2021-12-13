YANGS=$(wildcard $(YANG_PATH)/*.yang)

all: $(YANGS:$(YANG_PATH)/%.yang=$(COMPOSE_PATH)/%.yang)

# This is the first stage of preparing the nokia modules where we strip the
# "incorrect" extension usage statement and collect all processed YANG modules
# to a single directory. The next stage then has access to everything.
$(COMPOSE_PATH)/strip/%.yang: $(YANG_PATH)/%.yang
	@mkdir -p $(COMPOSE_PATH)/strip
# The extension instance appears in the 'meta-stms' header section in the YANG
# module - just before the 'organization' statement. libyang thinks that is not
# allowed, but looking at the YANG ABNF grammar we're not so sure. Extension
# statement instances are parsed as 'unknown-statement' which can appear
# anywhere! Let's strip the statement until libyang is fixed.
	sed -e '/sros-ext:sros-major-release/d' $< > $@

$(COMPOSE_PATH)/%.yang: $(COMPOSE_PATH)/strip/%.yang
	cp $< $@
	@mkdir -p $(COMPOSE_PATH)/install
# Mark the module for installation if it contains at least one data node. This
# saves time by skipping installation of nodes that only contain groupings or
# typedefs. Store pyang output in a temporary variable to ensure the YANG module
# gets marked for installation in case pyang (or xmlstarlet) fails to process
# the file.
	@if ! head -n1 $@ | grep -e '^submodule'; then \
		top_level_statements=$$(pyang --ignore-errors -f yin $@ -p $(COMPOSE_PATH)/strip | xmlstarlet sel -t -m '_:module/*' -v 'name()' -n); \
		if [ $$? -eq 0 ]; then echo $${top_level_statements} | grep -F -e container -e leaf -e leaf-list -e list -e choice -e anydata -e anyxml -e uses -e rpc -e action -e notification -e augment -e identity && touch $(COMPOSE_PATH)/install/$(@F); \
		else \
			touch $(COMPOSE_PATH)/install/$(@F); \
		fi \
	fi || true

YANGS=$(wildcard $(YANG_PATH)/*.yang)

all:$(YANGS:$(YANG_PATH)/%.yang=$(COMPOSE_PATH)/%.yang)

$(COMPOSE_PATH)/%.yang: $(YANG_PATH)/%.yang
	@mkdir -p $(COMPOSE_PATH)/install
# The extension instance appears in the 'meta-stms' header section in the YANG
# module - just before the 'organization' statement. libyang thinks that is not
# allowed, but looking at the YANG ABNF grammar we're not so sure. Extension
# statement instances are parsed as 'unknown-statement' which can appear
# anywhere! Let's strip the statement until libyang is fixed.
	sed -e '/sros-ext:sros-major-release/d' $< > $@
# Mark the module for installation if it contains at least one data node. This
# saves time by skipping installation of nodes that only contain groupings or
# typedefs.
	@if ! head -n1 $@ | grep -e '^submodule'; then \
		if pyang -f yin $@ -p $(YANG_PATH) | xmlstarlet sel -t -m '_:module/*' -v 'name()' -n | grep -F -e container -e leaf -e leaf-list -e list -e choice -e anydata -e anyxml -e uses -e rpc -e action -e notification -e augment; then touch $(COMPOSE_PATH)/install/$(@F); fi \
	fi

ELPA_DIR = $(CURDIR)/.elpa
SANDBOX_DIR = $(CURDIR)/.sandbox
MELPAZOID ?= $(HOME)/GitHub/riscy/melpazoid/melpazoid/melpazoid.el

# -Q and --batch do not relocate user-emacs-directory, and -Q skips
# early-init with it, so every unset default (eln cache, auto-save-list,
# transient history) resolves against whatever real config directory Emacs
# picks up.  --init-directory plus an explicit eln redirect keeps all of
# that inside .sandbox/ instead of littering someone's ~/.emacs.d.
# The redirect is guarded twice over: a build without native-compilation
# still defines startup-redirect-eln-cache, but leaves the variable it
# assigns to unbound.
EMACS_Q = emacs -Q --init-directory "$(SANDBOX_DIR)" \
	--eval "(when (and (featurep 'native-compile) (fboundp 'startup-redirect-eln-cache)) (startup-redirect-eln-cache \"$(SANDBOX_DIR)/eln-cache/\"))" \
	--eval "(setq package-user-dir \"$(ELPA_DIR)\")" \
	--eval "(require 'package)"

EMACS_BATCH = $(EMACS_Q) --batch \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	--eval "(package-initialize)"

EMACS_SANDBOX = $(EMACS_Q) \
	--eval "(package-initialize)"

.PHONY: help test test-embark test-e2e test-all deps lint checkdoc melpazoid check-autoloads check-compile compile clean sandbox

help:
	@echo "Available commands:"
	@echo "  make deps              Install dependencies"
	@echo "  make sandbox           Launch emacs -Q with consult-zoxide + embark loaded"
	@echo "  make lint              Run package-lint"
	@echo "  make checkdoc          Run checkdoc"
	@echo "  make melpazoid         Run melpazoid, the checks a MELPA reviewer runs"
	@echo "  make test              Run unit tests"
	@echo "  make test-embark       Run Embark integration tests"
	@echo "  make test-e2e          Run end-to-end tests against a real zoxide binary"
	@echo "  make test-all          Run all tests"
	@echo "  make compile           Byte-compile the package"
	@echo "  make check-autoloads   Generate and load autoloads"
	@echo "  make check-compile     Check for clean byte-compilation"
	@echo "  make clean             Remove compiled files"

$(SANDBOX_DIR):
	@mkdir -p $(SANDBOX_DIR)

$(ELPA_DIR): $(SANDBOX_DIR)
	@echo "Installing dependencies..."
	$(EMACS_BATCH) \
	--eval "(package-refresh-contents)" \
	--eval "(package-install 'buttercup)" \
	--eval "(package-install 'consult)" \
	--eval "(package-install 'embark)" \
	--eval "(package-install 'package-lint)" \
	--eval "(package-install 'pkg-info)"

deps: $(ELPA_DIR)

sandbox: $(ELPA_DIR)
	$(EMACS_SANDBOX) --directory . \
	--eval "(require 'embark)" \
	--eval "(require 'consult-zoxide)" \
	--eval "(require 'consult-zoxide-embark)" \
	--eval "(global-set-key (kbd \"C-.\") #'embark-act)" \
	--eval "(message \"consult-zoxide sandbox: M-x consult-zoxide | C-u M-x consult-zoxide for dead entries | C-. embark-act\")"

test: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/consult-zoxide-tests.el \
	--funcall buttercup-run

test-embark: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/consult-zoxide-embark-tests.el \
	--funcall buttercup-run

test-e2e: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/consult-zoxide-e2e-tests.el \
	--funcall buttercup-run

test-all: test test-embark test-e2e

lint: $(ELPA_DIR)
	@echo "Linting..."
	@# package-lint is what actually guards the declared Emacs minimum: it
	@# flags anything newer than the version in Package-Requires.  Nothing
	@# is filtered out of its output - MELPA's own CI does not filter
	@# either, so a locally hidden warning only surfaces during review.
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(require 'package-lint)" \
	--eval "(setq package-lint-main-file \"consult-zoxide.el\")" \
	-f package-lint-batch-and-exit consult-zoxide.el consult-zoxide-embark.el

checkdoc:
	@echo "Checking documentation strings..."
	@out=$$($(EMACS_Q) --batch \
	--eval "(require 'checkdoc)" \
	--eval "(dolist (f '(\"consult-zoxide.el\" \"consult-zoxide-embark.el\")) (checkdoc-file f))" 2>&1); \
	if [ -n "$$out" ]; then echo "$$out"; exit 1; else echo "checkdoc: clean"; fi

melpazoid: $(ELPA_DIR)
	@echo "Running melpazoid..."
	@test -f "$(MELPAZOID)" || { \
	echo "no melpazoid at $(MELPAZOID)"; \
	echo "clone https://github.com/riscy/melpazoid, or set MELPAZOID=/path/to/melpazoid.el"; \
	exit 1; }
	@# melpazoid resolves dependencies against (locate-user-emacs-file "elpa"),
	@# which --init-directory points into the sandbox
	@ln -sfn "$(ELPA_DIR)" "$(SANDBOX_DIR)/elpa"
	@# it checks every .el file beside the one it is pointed at, so give it
	@# only the two that ship - not the test suite, not this checkout
	@stage=$$(mktemp -d) && cp consult-zoxide.el consult-zoxide-embark.el $$stage/ && \
	out=$$(cd $$stage && PACKAGE_MAIN=consult-zoxide.el $(EMACS_BATCH) \
	--load="$(MELPAZOID)" 2>&1); \
	rm -rf $$stage; \
	if [ -n "$$out" ]; then echo "$$out"; exit 1; else echo "melpazoid: clean"; fi

check-autoloads:
	@echo "Generating and loading autoloads..."
	rm -f consult-zoxide-autoloads.el
	$(EMACS_BATCH) --directory . \
	--eval "(loaddefs-generate \"$(CURDIR)\" (expand-file-name \"consult-zoxide-autoloads.el\" \"$(CURDIR)\"))" \
	--eval "(load (expand-file-name \"consult-zoxide-autoloads.el\" \"$(CURDIR)\") nil 'nomessage)"

check-compile: $(ELPA_DIR)
	@echo "Checking byte-compilation..."
	$(EMACS_BATCH) \
	--eval "(setq byte-compile-error-on-warn t)" \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"consult-zoxide.el\")" \
	--eval "(byte-compile-file \"consult-zoxide-embark.el\")"
	@# a check, not a build: leaving .elc behind makes the next `make test`
	@# load stale bytecode instead of the source it is meant to exercise
	@rm -f *.elc

compile: $(ELPA_DIR)
	@echo "Byte-compiling package files..."
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"consult-zoxide.el\")" \
	--eval "(byte-compile-file \"consult-zoxide-embark.el\")"

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc consult-zoxide-autoloads.el
	rm -rf $(ELPA_DIR) $(SANDBOX_DIR)

# Makefile for runabs.sh
#
# By default installs to ~/.local (no sudo required).
# Override PREFIX for system-wide install:
#     sudo make install PREFIX=/usr/local
#
# Targets:
#     install       - install script + man page + license
#     uninstall     - remove installed files
#     check         - syntax check across multiple POSIX shells
#     lint          - run shellcheck (if installed)
#     test          - check + lint
#     dist          - build a distribution tarball
#     help          - this message

PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
MANDIR      ?= $(PREFIX)/share/man
MAN1DIR     ?= $(MANDIR)/man1
DOCDIR      ?= $(PREFIX)/share/doc/runabs

SCRIPT      := runabs.sh
MANPAGE     := runabs.1
README      := README.md
NODOCKER    := ABS_NO_DOCKER.md
APPLECONT   := ABS_APPLE_CONTAINER.md
CHANGELOG   := CHANGELOG.md
SECURITY    := SECURITY.md
GITIGNORE   := .gitignore
SHELLCHECK  := .shellcheckrc
LICENSE     := LICENSE
MAKEFILE    := Makefile

VERSION     := $(shell sed -n 's/^ABS_RUN_VERSION="\([^"]*\)"/\1/p' $(SCRIPT) | head -n 1)
DISTNAME    := runabs-$(VERSION)
DISTFILES   := $(SCRIPT) $(MANPAGE) $(README) $(NODOCKER) $(APPLECONT) $(CHANGELOG) $(SECURITY) $(GITIGNORE) $(SHELLCHECK) $(LICENSE) $(MAKEFILE)

INSTALLED_SCRIPT    := $(BINDIR)/$(SCRIPT)
INSTALLED_MANPAGE   := $(MAN1DIR)/$(MANPAGE)
INSTALLED_LICENSE   := $(DOCDIR)/$(LICENSE)
INSTALLED_README    := $(DOCDIR)/$(README)
INSTALLED_NODOCKER  := $(DOCDIR)/$(NODOCKER)
INSTALLED_APPLECONT := $(DOCDIR)/$(APPLECONT)
INSTALLED_CHANGELOG := $(DOCDIR)/$(CHANGELOG)
INSTALLED_SECURITY  := $(DOCDIR)/$(SECURITY)

# Detect platform for the right manpage-index rebuild command
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  MANDB_CMD := /usr/libexec/makewhatis $(MAN1DIR)
else ifeq ($(UNAME_S),FreeBSD)
  MANDB_CMD := makewhatis $(MAN1DIR)
else ifeq ($(UNAME_S),OpenBSD)
  MANDB_CMD := makewhatis $(MAN1DIR)
else ifeq ($(UNAME_S),NetBSD)
  MANDB_CMD := makewhatis $(MAN1DIR)
else
  MANDB_CMD := command -v mandb >/dev/null 2>&1 && mandb -q || true
endif

# Shells to syntax-check against (only those present are tested)
SHELLS_REQUIRED := sh dash bash posh
SHELLS_OPTIONAL := ash ksh busybox

.PHONY: help install uninstall check lint test reinstall dist bump clean

help:
	@echo 'runabs.sh installation'
	@echo ''
	@echo 'Usage:'
	@echo '  make install              # install to $$HOME/.local (no sudo)'
	@echo '  sudo make install \'
	@echo '    PREFIX=/usr/local       # install system-wide'
	@echo '  make uninstall            # remove installed files'
	@echo '  make check                # POSIX syntax check (all shells available)'
	@echo '  make lint                 # shellcheck (if installed)'
	@echo '  make test                 # check + lint'
	@echo '  make dist                 # build $(DISTNAME).tar.gz'
	@echo '  make bump TO=X.Y          # bump version in script/manpage/changelog'
	@echo '  make clean                # remove build artifacts (dist tarballs, bump tmp files)'
	@echo ''
	@echo 'Paths (override via PREFIX, BINDIR, MANDIR, MAN1DIR, DOCDIR):'
	@echo '  BINDIR  = $(BINDIR)'
	@echo '  MAN1DIR = $(MAN1DIR)'
	@echo '  DOCDIR  = $(DOCDIR)'
	@echo ''
	@echo 'Current install destinations:'
	@echo '  $(INSTALLED_SCRIPT)'
	@echo '  $(INSTALLED_MANPAGE)'
	@echo '  $(INSTALLED_LICENSE)'
	@echo '  $(INSTALLED_README)'
	@echo '  $(INSTALLED_NODOCKER)'
	@echo '  $(INSTALLED_APPLECONT)'
	@echo '  $(INSTALLED_CHANGELOG)'
	@echo '  $(INSTALLED_SECURITY)'

install: $(SCRIPT) $(MANPAGE) $(LICENSE) $(README) $(NODOCKER) $(APPLECONT) $(CHANGELOG) $(SECURITY)
	@mkdir -p $(BINDIR) $(MAN1DIR) $(DOCDIR)
	install -m 755 $(SCRIPT)    $(INSTALLED_SCRIPT)
	install -m 644 $(MANPAGE)   $(INSTALLED_MANPAGE)
	install -m 644 $(LICENSE)   $(INSTALLED_LICENSE)
	install -m 644 $(README)    $(INSTALLED_README)
	install -m 644 $(NODOCKER)  $(INSTALLED_NODOCKER)
	install -m 644 $(APPLECONT) $(INSTALLED_APPLECONT)
	install -m 644 $(CHANGELOG) $(INSTALLED_CHANGELOG)
	install -m 644 $(SECURITY)  $(INSTALLED_SECURITY)
	@echo ''
	@echo "Installed:"
	@echo "  $(INSTALLED_SCRIPT)"
	@echo "  $(INSTALLED_MANPAGE)"
	@echo "  $(INSTALLED_LICENSE)"
	@echo "  $(INSTALLED_README)"
	@echo "  $(INSTALLED_NODOCKER)"
	@echo "  $(INSTALLED_APPLECONT)"
	@echo "  $(INSTALLED_CHANGELOG)"
	@echo "  $(INSTALLED_SECURITY)"
	@$(MANDB_CMD) 2>/dev/null || true
	@case ":$$PATH:" in \
	  *:$(BINDIR):*) ;; \
	  *) echo ''; \
	     echo 'Note: $(BINDIR) is not in your PATH.'; \
	     echo 'Add to your shell profile:'; \
	     echo '  export PATH="$(BINDIR):$$PATH"'; \
	     ;; \
	esac
	@if ! manpath 2>/dev/null | tr ':' '\n' | grep -qx "$(MANDIR)"; then \
	  echo ''; \
	  echo 'Note: $(MANDIR) is not in your manpath.'; \
	  echo 'Add to your shell profile (or /etc/manpath.config):'; \
	  echo '  export MANPATH="$(MANDIR):$$MANPATH"'; \
	fi

uninstall:
	@rm -f $(INSTALLED_SCRIPT)    && echo "Removed $(INSTALLED_SCRIPT)"    || true
	@rm -f $(INSTALLED_MANPAGE)   && echo "Removed $(INSTALLED_MANPAGE)"   || true
	@rm -f $(INSTALLED_LICENSE)   && echo "Removed $(INSTALLED_LICENSE)"   || true
	@rm -f $(INSTALLED_README)    && echo "Removed $(INSTALLED_README)"    || true
	@rm -f $(INSTALLED_NODOCKER)  && echo "Removed $(INSTALLED_NODOCKER)"  || true
	@rm -f $(INSTALLED_APPLECONT) && echo "Removed $(INSTALLED_APPLECONT)" || true
	@rm -f $(INSTALLED_CHANGELOG) && echo "Removed $(INSTALLED_CHANGELOG)" || true
	@rm -f $(INSTALLED_SECURITY)  && echo "Removed $(INSTALLED_SECURITY)"  || true
	@rmdir $(DOCDIR) 2>/dev/null || true
	@$(MANDB_CMD) 2>/dev/null || true

reinstall: uninstall install

check:
	@echo 'POSIX syntax check (required shells):'
	@for sh in $(SHELLS_REQUIRED); do \
	  if command -v $$sh >/dev/null 2>&1; then \
	    if $$sh -n $(SCRIPT) 2>/dev/null; then \
	      printf '  %-10s OK\n' "$$sh:"; \
	    else \
	      printf '  %-10s FAIL\n' "$$sh:"; \
	      exit 1; \
	    fi; \
	  fi; \
	done
	@# Optional shells: report status but do not gate the target. These
	@# include shells where a "FAIL" might mean the parser segfaulted or
	@# rejected a construct that's valid POSIX. The script is targeted at
	@# the required set; the optional set is opportunistic coverage.
	@any_optional=0; \
	for sh in $(SHELLS_OPTIONAL); do \
	  if command -v $$sh >/dev/null 2>&1; then \
	    any_optional=1; break; \
	  fi; \
	done; \
	if [ "$$any_optional" = "1" ]; then \
	  echo ''; \
	  echo 'POSIX syntax check (optional shells, informational only):'; \
	  for sh in $(SHELLS_OPTIONAL); do \
	    if command -v $$sh >/dev/null 2>&1; then \
	      if $$sh -n $(SCRIPT) 2>/dev/null; then \
	        printf '  %-10s OK\n' "$$sh:"; \
	      else \
	        printf '  %-10s SKIP (parser rejected; not a script bug if required shells pass)\n' "$$sh:"; \
	      fi; \
	    fi; \
	  done; \
	fi

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo 'shellcheck:'; \
	  shellcheck $(SCRIPT) && \
	    echo '  clean' || true; \
	else \
	  echo 'shellcheck not installed; skipping.'; \
	  echo '  Install:  brew install shellcheck   (macOS)'; \
	  echo '         or apt install shellcheck   (Debian/Ubuntu)'; \
	fi

test: check lint

dist: $(DISTFILES)
	@echo 'Building $(DISTNAME).tar.gz...'
	@rm -rf $(DISTNAME) $(DISTNAME).tar.gz
	@mkdir $(DISTNAME)
	@cp $(DISTFILES) $(DISTNAME)/
	@chmod 755 $(DISTNAME)/$(SCRIPT) 2>/dev/null || true
	@tar -czf $(DISTNAME).tar.gz $(DISTNAME)
	@rm -rf $(DISTNAME)
	@# Verify the +x bit made it into the tarball. If the working
	@# filesystem stripped it (some overlay/CIFS mounts do this even
	@# after chmod), rebuild via a temp directory that supports +x.
	@if ! tar -tzvf $(DISTNAME).tar.gz | grep -E '^-[r-][w-]x.*$(SCRIPT)$$' >/dev/null 2>&1; then \
	  echo "Note: working filesystem stripped +x; rebuilding via /tmp"; \
	  dist_rebuild_tmp=$$(mktemp -d) && \
	  tar -xzf $(DISTNAME).tar.gz -C "$$dist_rebuild_tmp" && \
	  chmod 755 "$$dist_rebuild_tmp/$(DISTNAME)/$(SCRIPT)" && \
	  ( cd "$$dist_rebuild_tmp" && tar -czf - $(DISTNAME) ) > $(DISTNAME).tar.gz && \
	  rm -rf "$$dist_rebuild_tmp"; \
	fi
	@# Post-build sanity check: extract the archive into a temp dir and
	@# confirm the script comes out executable.
	@dist_verify_tmp=$$(mktemp -d) && \
	  tar -xzf $(DISTNAME).tar.gz -C "$$dist_verify_tmp" $(DISTNAME)/$(SCRIPT) && \
	  test -x "$$dist_verify_tmp/$(DISTNAME)/$(SCRIPT)" && \
	  rm -rf "$$dist_verify_tmp" && \
	  echo 'Sanity check: extracted script is executable.' || \
	  { echo 'ERROR: dist archive failed sanity check.' >&2; \
	    rm -rf "$$dist_verify_tmp" 2>/dev/null; exit 1; }
	@echo ""
	@echo "Wrote: $(DISTNAME).tar.gz"
	@echo ""
	@echo "Contents:"
	@tar -tzf $(DISTNAME).tar.gz | sed 's/^/  /'
	@echo ""
	@if command -v sha256sum >/dev/null 2>&1; then \
	  sha256sum $(DISTNAME).tar.gz; \
	elif command -v shasum >/dev/null 2>&1; then \
	  shasum -a 256 $(DISTNAME).tar.gz; \
	fi

# ---------------------------------------------------------------------------
# Version bump
# ---------------------------------------------------------------------------
#
# Usage:
#   make bump TO=4.1
#
# What it does:
#   1. Refuses to run if the git working tree is dirty (commit/stash first).
#   2. Updates ABS_RUN_VERSION in runabs.sh.
#   3. Updates the .TH line in runabs.1 (version + month/year).
#   4. Inserts a new heading + reference link in CHANGELOG.md.
#   5. Prints the next steps (edit CHANGELOG body, commit, tag, push).
#
# What it does NOT do:
#   - Generate changelog content. You write that.
#   - Commit, tag, or push. You do that, deliberately, after reviewing.
#   - Build the dist archive. Run `make dist` separately when ready.
#
# Portability note: BSD and GNU sed handle -i differently (BSD requires a
# backup-extension argument, GNU treats one as part of the filename). To
# stay portable, we write to a temp file and mv into place.

# Current date for the man page .TH line ("Month Year" style)
BUMP_DATE := $(shell date '+%B %Y')
# ISO month for CHANGELOG heading (YYYY-MM)
BUMP_DATE_ISO := $(shell date '+%Y-%m')

# Note: the input arg is TO=, not VERSION=, because VERSION is already a
# Makefile variable holding the *current* version (read from runabs.sh near
# the top of this file). Using TO= keeps the two cleanly distinct.

bump:
	@if [ -z "$(TO)" ]; then \
	  echo 'ERROR: TO not set.'; \
	  echo 'Usage: make bump TO=4.1'; \
	  exit 1; \
	fi
	@if [ "$(TO)" = "$(VERSION)" ]; then \
	  echo 'ERROR: requested version $(TO) matches current version.'; \
	  exit 1; \
	fi
	@if command -v git >/dev/null 2>&1 && [ -d .git ]; then \
	  if [ -n "$$(git status --porcelain 2>/dev/null)" ]; then \
	    echo 'ERROR: git working tree is dirty.'; \
	    echo '  Commit or stash your changes first, so the version bump is a clean commit.'; \
	    git status --short; \
	    exit 1; \
	  fi; \
	fi
	@echo "Bumping version: $(VERSION) -> $(TO)"
	@echo "Release date:    $(BUMP_DATE) ($(BUMP_DATE_ISO))"
	@echo ''
	@# 1. runabs.sh
	@sed 's/^ABS_RUN_VERSION="[^"]*"/ABS_RUN_VERSION="$(TO)"/' \
	    $(SCRIPT) > $(SCRIPT).bump.tmp
	@mv $(SCRIPT).bump.tmp $(SCRIPT)
	@chmod 755 $(SCRIPT)
	@echo '  Updated $(SCRIPT): ABS_RUN_VERSION="$(TO)"'
	@# 2. runabs.1 - replace both date and version in the .TH line
	@sed 's/^\.TH RUNABS 1 "[^"]*" "runabs\.sh [^"]*"/.TH RUNABS 1 "$(BUMP_DATE)" "runabs.sh $(TO)"/' \
	    $(MANPAGE) > $(MANPAGE).bump.tmp
	@mv $(MANPAGE).bump.tmp $(MANPAGE)
	@echo '  Updated $(MANPAGE): .TH date+version'
	@# 3. CHANGELOG.md - insert new heading at the first existing heading,
	@#    plus the reference link at the first existing reference link.
	@awk -v ver='$(TO)' -v date='$(BUMP_DATE_ISO)' -v repo='katertier/runabs' '\
	  /^## \[/ && !inserted { \
	    print "## [" ver "] \xe2\x80\x94 " date; \
	    print ""; \
	    print "### Added"; \
	    print ""; \
	    print "- (describe changes here)"; \
	    print ""; \
	    print "### Fixed"; \
	    print ""; \
	    print "- (describe fixes here)"; \
	    print ""; \
	    inserted = 1; \
	  } \
	  /^\[[0-9]/ && !ref_inserted { \
	    print "[" ver "]: https://github.com/" repo "/releases/tag/v" ver; \
	    ref_inserted = 1; \
	  } \
	  { print } \
	' $(CHANGELOG) > $(CHANGELOG).bump.tmp
	@mv $(CHANGELOG).bump.tmp $(CHANGELOG)
	@echo '  Updated $(CHANGELOG): added stub entry for $(TO)'
	@echo ''
	@echo 'Next steps:'
	@echo '  1. Edit $(CHANGELOG) - replace the stub with real release notes.'
	@echo '  2. Review the diff:    git diff'
	@echo '  3. Run the tests:      make test'
	@echo '  4. Build the archive:  make dist'
	@echo '  5. Commit and tag:     git commit -am "Release v$(TO)" && git tag v$(TO)'
	@echo '  6. Push:               git push && git push --tags'
	@echo '  7. Create the GitHub release and attach runabs-$(TO).tar.gz.'

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
#
# Removes build artifacts produced by `make dist` and the bump target.
# Does NOT remove installed files (use `make uninstall` for that).

clean:
	@rm -rf runabs-*.tar.gz runabs-*/ \
	        $(SCRIPT).bump.tmp $(MANPAGE).bump.tmp $(CHANGELOG).bump.tmp
	@echo 'Cleaned build artifacts.'

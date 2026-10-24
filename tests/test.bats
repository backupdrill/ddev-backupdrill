#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure
#
# The drill runs on the host, so the machine running these tests needs what
# `ddev backupdrill` needs: Docker, Node.js 20+, and pg_dump/pg_restore whose
# major version is at least the project's Postgres version (16 here).

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=backupdrill/ddev-backupdrill

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --database=postgres:16
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # Two tables with a foreign key and 1,250 rows, so the drill has something to restore
  run ddev psql -v ON_ERROR_STOP=1 -c "
    create table customers (id int primary key, name text not null);
    create table orders (id int primary key, customer_id int not null references customers(id), total numeric not null);
    insert into customers select g, 'customer ' || g from generate_series(1, 250) g;
    insert into orders select g, 1 + g % 250, g * 1.5 from generate_series(1, 1000) g;"
  assert_success

  run ddev backupdrill
  assert_success
  assert_output --partial "Backup complete"
  assert_output --partial "Drill PASSED"
  assert_output --partial "2 tables / 1,250 rows restored"

  # The temporary S3 container must be gone once the command exits
  run docker ps -aq --filter "label=com.backupdrill.ddev-project=${PROJNAME}"
  assert_success
  assert_output ""

  # Flags that could point the CLI at real storage or monitoring are refused
  # before anything starts
  run ddev backupdrill --config "${TESTDIR}/backupdrill.config.json"
  assert_failure
  assert_output --partial "unsupported option '--config'"
  run ddev backupdrill --ping-url=https://hc-ping.invalid/check
  assert_failure
  assert_output --partial "unsupported option '--ping-url=https://hc-ping.invalid/check'"
}

# Ctrl+C sends SIGINT to the whole foreground process group; do the same to a
# run in its own group and check the bucket container is removed anyway.
interrupt_check() {
  # A background job of a non-interactive shell starts with SIGINT ignored and
  # exec keeps that, so put it back to the default before handing over to ddev.
  perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' ddev backupdrill >"${TESTDIR}/interrupted.log" 2>&1 3>&- &
  local pid=$!
  local bucket=""
  for _ in $(seq 1 120); do
    bucket="$(docker ps -q --filter "label=com.backupdrill.ddev-project=${PROJNAME}")"
    [ -n "${bucket}" ] && break
    sleep 0.5
  done
  [ -n "${bucket}" ]
  kill -INT -- "-${pid}"

  # Up to 60 seconds to clean up and exit, then it has to be gone
  for _ in $(seq 1 120); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  run kill -0 "${pid}"
  assert_failure
  local status=0
  wait "${pid}" || status=$?
  # A run that finished on its own exits 0 and prints "Drill PASSED"
  [ "${status}" -ne 0 ]

  # ddev can exit on the signal before the command's own cleanup is done,
  # so wait for the cleanup to report back
  for _ in $(seq 1 60); do
    grep -q "Removed the temporary bucket" "${TESTDIR}/interrupted.log" && break
    sleep 0.5
  done
  run cat "${TESTDIR}/interrupted.log"
  refute_output --partial "Drill PASSED"
  assert_output --partial "Removed the temporary bucket"

  run docker ps -aq --filter "label=com.backupdrill.ddev-project=${PROJNAME}"
  assert_success
  assert_output ""
}

# backupdrill 2.7.0 and later clean up after themselves on Ctrl+C. Interrupt once the
# drill's sandbox is up and check it, the bucket and the CLI's process are all gone.
sandbox_interrupt_check() {
  # Other projects on this machine may have their own backupdrill-drill-* sandboxes
  # (running, or kept with --keep). Only look at the one this run starts.
  local before
  before="$(docker ps -aq --no-trunc --filter "name=backupdrill-drill-" | sort)"
  perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' ddev backupdrill >"${TESTDIR}/sandbox-interrupted.log" 2>&1 3>&- &
  local pid=$!
  # Globals, not locals: teardown cleans these up if an assertion below fails
  INTERRUPTED_PGID="${pid}"
  local sandbox=""
  for _ in $(seq 1 600); do
    sandbox="$(comm -13 <(echo "${before}") <(docker ps -q --no-trunc --filter "name=backupdrill-drill-" | sort) | head -n 1)"
    [ -n "${sandbox}" ] && break
    sleep 0.2
  done
  INTERRUPTED_SANDBOX="${sandbox}"
  [ -n "${sandbox}" ]
  # Signal the whole process group, the way Ctrl+C in a terminal does
  kill -INT -- "-${pid}"

  # Wait for the whole group, not just ddev: the CLI is in it, and an orphaned CLI
  # still cleaning up (or stuck) must fail the test
  for _ in $(seq 1 120); do
    kill -0 -- "-${pid}" 2>/dev/null || break
    sleep 0.5
  done
  run kill -0 -- "-${pid}"
  assert_failure
  local status=0
  wait "${pid}" || status=$?
  [ "${status}" -ne 0 ]

  for _ in $(seq 1 60); do
    grep -q "Removed the temporary bucket" "${TESTDIR}/sandbox-interrupted.log" && break
    sleep 0.5
  done
  run cat "${TESTDIR}/sandbox-interrupted.log"
  refute_output --partial "Drill PASSED"
  assert_output --partial "stopping the drill and cleaning up"
  # npx forwards the SIGINT a second time; backupdrill 2.7.0 took that as a second
  # Ctrl+C and skipped the cleanup (fixed in 2.7.1)
  refute_output --partial "again — exiting without finishing the cleanup"
  assert_output --partial "Removed the temporary bucket"

  run docker ps -aq --no-trunc --filter "id=${sandbox}"
  assert_success
  assert_output ""
  run docker ps -aq --filter "label=com.backupdrill.ddev-project=${PROJNAME}"
  assert_success
  assert_output ""
}

teardown() {
  set -eu -o pipefail
  # A failed assertion in sandbox_interrupt_check returns before its own checks run, which
  # can leave the CLI, its sandbox and the temporary bucket behind
  if [ -n "${INTERRUPTED_PGID:-}" ]; then
    kill -KILL -- "-${INTERRUPTED_PGID}" 2>/dev/null || true
  fi
  if [ -n "${INTERRUPTED_SANDBOX:-}" ]; then
    docker rm -fv "${INTERRUPTED_SANDBOX}" >/dev/null 2>&1 || true
  fi
  for container in $(docker ps -aq --filter "label=com.backupdrill.ddev-project=${PROJNAME}"); do
    docker rm -fv "${container}" >/dev/null 2>&1 || true
  done
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  interrupt_check
  sandbox_interrupt_check
}

@test "refuses a project that isn't on Postgres" {
  set -eu -o pipefail
  run ddev config --database=mariadb:11.8
  assert_success
  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "only works with a Postgres database"
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

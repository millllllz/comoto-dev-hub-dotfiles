# Expose some helpful bash functions to codify access to different tools
# provided by docker.
#
export PROJECT_ROOT=/workspaces
export COMOTO_PROJECT_ROOT=/workspaces

if [[ -d $COMOTO_PROJECT_ROOT ]]; then
  export PROJECT_ROOT=$COMOTO_PROJECT_ROOT
elif [[ ${0} == *bash ]]; then
  export PROJECT_ROOT=$(readlink -f "$(dirname ${BASH_SOURCE[0]})/../../../")
else
  export PROJECT_ROOT=$(readlink -f "$(dirname ${0})/../../../")
fi
export ANSIBLE_ROOT=${HOME}/.ansible

export COMPOSE_ROOT=${PROJECT_ROOT}/monorepo
export ZV_SCRIPTS=${PROJECT_ROOT}/monorepo/zlaverse/support/bash_functions
export COMOTO_DEVTOOLS=${PROJECT_ROOT}/monorepo/zlaverse/support/devtools

source $COMOTO_DEVTOOLS/devtools.sh

# Source the functions for our various support services
#
# If you are doing local development for any of these services then update your .bashrc or equivalent to source
# the bash_functions.sh provided in that service's repo. It must be sourced after this file is sourced to ensure the
# functions provided are correctly overridden to the repo's versions.
# source $ZV_SCRIPTS/loyalty_api.sh
# source $ZV_SCRIPTS/message_failure_service.sh
# source $ZV_SCRIPTS/product_search_service.sh
# source $ZV_SCRIPTS/product_service.sh
# source $ZV_SCRIPTS/payment_service.sh
# source $ZV_SCRIPTS/admin.sh
# source $ZV_SCRIPTS/jobs.sh

#
# GENERIC
#
function container-restart() {
  (cd $COMPOSE_ROOT && docker compose restart $1)
}

function container-log() {
  (cd $COMPOSE_ROOT && docker compose logs -f $1)
}

function container-bash() {
  (cd $COMPOSE_ROOT && docker compose exec $1 bash -lc "TERM=xterm-color bash -l")
}

function container-stats() {
  docker stats $(docker ps --format={{.Names}})
}

function container-log-purge() {
  (cd $COMPOSE_ROOT && docker run --rm --privileged --pid=host debian nsenter -t 1 -m -u -n -i sh -c ">$(docker inspect -f '{{.LogPath}}' $(docker compose ps $1 --format '{{.Name}}'))")
}

#
# APP ECOM
#

function ecom-bash() {
  cd $COMPOSE_ROOT;
  if [[ $1 == "" ]]; then
    docker compose exec -u deploy ecom-webapp bash -lc "TERM=xterm-color bash -l"
  else
    docker compose exec -u deploy ecom-webapp bash -lc "$1"
  fi
  cd -;
}

function ecom-debug() {
  (cd $COMPOSE_ROOT && docker attach $(docker compose ps ecom-webapp --format '{{.Name}}'));
}

function ecom-console() {
  ecom-bash 'TERM=xterm-color script/console'
}

function ecom-load-test-schema() {
  ecom-bash 'RAILS_ENV=test; rake db:test:reset_and_load_seed'
}

function ecom-test() {
  if [[ $1 == "" ]]; then
    ecom-bash "rake test:units"
  else
    ecom-bash "rake test:units TEST=test/unit/$1"
  fi
}

function ecom-assets() {
  ecom-bash "rake asset:packager:build_all"
}

# force css to compile
function sass-now() {
  ecom-bash "sass --style=compressed --sourcemap=none --update --force /rz/ecom/current/public/sass/:/rz/ecom/current/public/stylesheets/;"
}

#
# POSTGRES
#
function postgres-dump-restore() {
  bin_file=""
  if [ "$1x" = "x" ]; then
    bin_file="";
  else
    if [ $(uname) = 'Linux' ]
    then
      bin_file=`readlink -f $1`
    else
      bin_file=`greadlink -f $1`
    fi

    if [ ! -f $bin_file ]
    then
      echo "The pgdump $bin_file does not exist."
      return 1
    else
      echo "Restoring: $bin_file"
    fi
  fi

  echo "Fetching list of ecom database backups...";
  PS3="Select a backup to restore (q to quit): "; select backup in $bin_file $(gsutil ls gs://rz-db-dumps/ecom-sanitized-\[0-9\]\*); do
    if [ "${backup}x" = "x" ]; then
      echo "Restore cancelled!";
    else
      if [ "${backup}" = "${bin_file}" ]; then
        GSUTIL="";
        backup_file=${bin_file}
      else
        GSUTIL="gsutil";
        echo "Pulling ${backup}"
        backup_file=./ecom.dump
        $GSUTIL cp ${backup} ${backup_file} # copy chosen dump to hard-coded path
      fi
      echo "Shutting down all containers...";
      (cd ${COMPOSE_ROOT} && docker compose down)
      docker rm pg_recovery; # make sure the last run is cleared
      docker run -d --rm -v $(cd ${COMPOSE_ROOT} && docker compose config --format json | jq -r '.volumes["postgres14_data"].name'):/var/lib/postgresql/data -v ${backup_file}:/pgbackup.dump \
        -e PGDATA=/var/lib/postgresql/data/data -e POSTGRES_PASSWORD='PG92d3vp@assw0rd' -e PGPASSWORD='PG92d3vp@assw0rd' -e POSTGRES_HOST_AUTH_METHOD=password \
        --name pg_recovery postgres:14
      echo "Waiting for DB to start...";
      sleep 10
      echo "DROP DATABASE IF EXISTS ecom;" | docker exec -i -u postgres pg_recovery psql;
      echo "CREATE DATABASE ecom;" | docker exec -i -u postgres pg_recovery psql;
      docker exec -ti -u postgres pg_recovery bash -lc "sed -i -e 's/scram-sha-256/password/' /var/lib/postgresql/data/data/pg_hba.conf"
      docker exec -ti -u postgres pg_recovery bash -lc "pg_restore -j4 -O -x -U postgres -d ecom  /pgbackup.dump"
      docker stop pg_recovery;
      echo "If successful, clean up the local dump file by running: rm ${backup}"
    fi;
    break;
  done
}

function postgres-psql() {
  cd $COMPOSE_ROOT;
  docker exec -ti -e PGPASSWORD='PG92d3vp@assw0rd' -u postgres $(docker compose ps postgres14 --format '{{.Name}}') postgres -h localhost ecom;
  cd -;
}

#
# CG
#
function cg-bash() {
  $COMOTO_DEVTOOLS/redline_bash.sh cg "$@"
}

function cg-iex() {
  cg-bash 'TERM=xterm-color iex --sname cg --remsh cg@`hostname` \
    --cookie redline_D3V_oreos'
}

function cg-load-test-schema() {
  cg-bash '(export MIX_ENV=test && mix compile && cd apps/redline_core_model && mix ecto.reset_test_repo)'
}

function cg-mix-credo() {
  echo 'cg-mix-credo is deprecated. Use `redline-check -c` instead' >&2
  # Note that `redline-check -c` does away with the `--all`, `--all-priorities`, and `--strict` options.
  # This is because those opts aren't used in CI.
  cg-bash 'TERM=xterm-color mix credo --all --all-priorities --strict'
}

function cg-mix-coveralls() {
  cg-bash "TERM=xterm-color MIX_ENV=test mix coveralls -u $*"
}

function cg-mix-coveralls-detail() {
  cg-bash "TERM=xterm-color MIX_ENV=test mix coveralls.detail -u $*"
}

function cg-mix-coveralls-app() {
  local d=$1
  shift
  cg-bash "cd apps/${d} && TERM=xterm-color MIX_ENV=test mix coveralls $*"
}

# This is useful for when you just want to check coverage of a single file in an app.
# cg-mix-coveralls-detail-app redline_web_store --filter lib/web_store.ex
function cg-mix-coveralls-detail-app() {
  local d=$1
  shift
  cg-bash "cd apps/${d} && TERM=xterm-color MIX_ENV=test mix coveralls.detail $*"
}

# Run a test for the entire Redline umbrella
alias cg-mix-test='redline-mix test --warnings-as-errors'


# Run a test for a single app within the Redline umbrella.
# Usage examples:
#   cg-mix-text-app redline_web_store
#   cg-mix-text-app redline_web_store --trace
#   cg-mix-text-app redline_web_store --trace --exclude noisy_local_tests
#   cg-mix-text-app redline_web_store --failed
function cg-mix-test-app() {
  dir="apps/$1"
  shift
  cg-bash "cd $dir && TERM=xterm-color mix test --warnings-as-errors $*"
}

function cg-product-catalog-reindex() {
  # this starts a full beam instance, which activates npm watchers, etc.
  # ideally, it would connect to the running process and issue the `perform` there...
  cg-bash 'iex -S mix redline.product_catalog.build_index'
}

function cg-webpack() {
  cg-bash "cd /rz/redline/apps/redline_web_store && ./node_modules/webpack/bin/webpack.js --config webpack.dev.js"
}

function cg-webpack-prod() {
  cg-bash "cd /rz/redline/apps/redline_web_store && ./node_modules/webpack/bin/webpack.js --config webpack.prod.js --node-env=production"
}

function cg-webpack-profile() {
  cg-bash "cd /rz/redline/apps/redline_web_store && ./node_modules/webpack/bin/webpack.js --config webpack.profile.js"
}

function cg-format() {
  echo "cg-format is deprecated. Use redline-format instead"
  redline-format "$@"
}

#
# JP
#
function jp-bash() {
  $COMOTO_DEVTOOLS/redline_bash.sh jp "$@"
}

function jp-iex() {
  jp-bash 'TERM=xterm-color iex --sname jp --remsh jp@`hostname` \
    --cookie redline_D3V_oreos'
}

#
# RZ
#
function rz-bash() {
  $COMOTO_DEVTOOLS/redline_bash.sh rz "$@"
}

function rz-iex() {
  rz-bash 'TERM=xterm-color iex --sname rz --remsh rz@`hostname` \
    --cookie redline_D3V_oreos'
}

function rz-load-test-schema() {
  rz-bash '(export MIX_ENV=test && mix compile && cd apps/redline_core_model && mix ecto.reset_test_repo)'
}

function rz-mix-credo() {
  echo 'rz-mix-credo is deprecated. Use `redline-check -c` instead' >&2
  # Note that `redline-check -c` does away with the `--all`, `--all-priorities`, `--strict`, and `--ignore Consistency` options.
  # This is because those opts aren't used in CI.
  rz-bash 'TERM=xterm-color mix credo --all --all-priorities --strict --ignore Consistency'
}

function rz-mix-coveralls() {
  rz-bash "TERM=xterm-color MIX_ENV=test mix coveralls -u $*"
}

function rz-mix-coveralls-detail() {
  rz-bash "TERM=xterm-color MIX_ENV=test mix coveralls.detail -u $*"
}

function rz-mix-coveralls-app() {
  local d=$1
  shift
  rz-bash "cd apps/${d} && TERM=xterm-color MIX_ENV=test mix coveralls $*"
}

# This is useful for when you just want to check coverage of a single file in an app.
# rz-mix-coveralls-detail-app redline_web_store --filter lib/web_store.ex
function rz-mix-coveralls-detail-app() {
  local d=$1
  shift
  rz-bash "cd apps/${d} && TERM=xterm-color MIX_ENV=test mix coveralls.detail $*"
}

# Run a test for the entire Redline umbrella
function rz-mix-test() {
  echo -e "\a\n\n\nDANGER: Currently all CircleCI tests run from CG. You should probably use cg-mix-test instead to avoid false alarms.\n\n\n"
  rz-bash "TERM=xterm-color mix test $1 --warnings-as-errors"
}

# Run a test for a single app within the Redline umbrella.
function rz-mix-test-app() {
  echo -e "\a\n\n\nDANGER: Currently all CircleCI tests run from CG. You should probably use cg-mix-test instead to avoid false alarms.\n\n\n"
  rz-bash "cd apps/$1 && TERM=xterm-color mix test $2 --warnings-as-errors"
}

function rz-product-catalog-reindex() {
  # this starts a full beam instance, which activates npm watchers, etc.
  # ideally, it would connect to the running process and issue the `perform` there...
  rz-bash 'iex -S mix redline.product_catalog.build_index'
}

function rz-webpack() {
  rz-bash "cd /rz/redline/apps/redline_web_store && ./node_modules/webpack/bin/webpack.js --config webpack.dev.js"
}

function rz-webpack-prod() {
  rz-bash "cd /rz/redline/apps/redline_web_store && ./node_modules/webpack/bin/webpack.js --config webpack.prod.js --node-env=production"
}

function rz-seed-product-service() {
  rz-bash 'iex -S mix seed_product_service'
}

function rz-format() {
  echo "rz-format is deprecated. Use redline-format instead"
  redline-format "$@"
}

function pods() {
  kubectl get pods $1
}

function watch-pods() {
  watch kubectl get pods $1
}

function cron-pods() {
  kubectl get pods -l app=cronjob --field-selector status.phase=Running -o 'custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp,NODE:.spec.nodeName,ARG:.spec.containers[0].args[0]' --sort-by=.status.startTime $1
}

function watch-cron-pods() {
  watch kubectl get pods -l app=cronjob --field-selector status.phase=Running -o 'custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp,NODE:.spec.nodeName,ARG:.spec.containers[0].args[0]' --sort-by=.status.startTime $1
}

function cg-podsh() {
  kubectl exec -it deployment/cycle-gear-redline-webapp -- bash
}

function rz-podsh() {
  kubectl exec -it deployment/revzilla-redline-webapp -- bash
}

function ecom-podsh() {
  kubectl exec -it deployment/ecom-webapp -- bash
}

function cron-status() {
  kubectl get pods -l app=cronjob -o jsonpath='{range .items[*]}Pod {.metadata.name}, running cron job {.spec.containers[*].args} status is {.status.phase}{"\n"}{end}' -a
}

function gcloud-prod() {
  gcloud config configurations activate production
}

function gcloud-staging() {
  gcloud config configurations activate default
}

function kube-prod() {
  kube-conf production
}

function kube-staging() {
  kube-conf staging
}

function kube-conf() {
  kubectl config use-context $1
}

function kube-bash() {
  local namespace=${2:-'default'}
  local pod=`kubectl get pods -n ${namespace} | grep -m 1 $1 | sed 's/ .*//'`
  echo "kubectl exec -ti ${pod} -n ${namespace} -- bash"
  kubectl exec -ti $pod -n ${namespace} -- bash
}

function kube-sh() {
  local namespace=${2:-'default'}
  local pod=`kubectl get pods -n ${namespace} | grep -m 1 $1 | sed 's/ .*//'`
  echo "kubectl exec -ti ${pod} -n ${namespace} -- sh"
  kubectl exec -ti $pod -n ${namespace} -- sh
}

function kube-iex() {
  local namespace=${1:-'default'}
  local pod=`kubectl get pods -n ${namespace} | grep Running | grep -m 1 revzilla-redline | sed 's/ .*//'`
  echo "kubectl exec -ti $pod -n ${namespace} -- bash -c './bin/redline remote'"
  kubectl exec -ti $pod -n ${namespace} -- bash -c './bin/redline remote'
}

function kube-irb() {
  local namespace=${1:-'default'}
  local pod=`kubectl get pods -n ${namespace} | grep Running | grep -m 1 ecom-webapp | sed 's/ .*//'`
  echo "kubectl exec -ti $pod -n ${namespace} -- bash -c 'PATH=/usr/local/rbenv/shims:\$PATH && ./script/console'"
  kubectl exec -ti $pod -n ${namespace} -- bash -c 'PATH=/usr/local/rbenv/shims:$PATH && ./script/console'
}

function cd_zla() {
  echo cd ${PROJECT_ROOT}/monorepo/zlaverse/dev
  cd ${PROJECT_ROOT}/monorepo/zlaverse/dev
}

function cd_k8s() {
  echo cd ${PROJECT_ROOT}/monorepo/k8s
  cd ${PROJECT_ROOT}/monorepo/k8s
}

# create a new migration file - usage: create_migration migration_name_with_underscores
function create_migration() {
  date=`date +%Y_%m_%d`
  name="_${USER//./}_"
  filename="$date$name$1"
  filepath="$PROJECT_ROOT/monorepo/ecom/db/migrate/$filename.rb"
  classname=`echo $1 | perl -pe 's/(^|_)(\w)/\U$2/g'`

  cat << EOF > $filepath
class $classname < ActiveRecord::Migration
  def self.up
    execute(%Q(
      UP_QUERY_GOES_HERE
    ))
  end

  def self.down
    execute(%Q(
      DOWN_QUERY_GOES_HERE
    ))
  end
end
EOF
}

# USAGE:        https://hexdocs.comoto.io/platform/readme.html#create-a-platform-application
# CONTRIBUTING: https://hexdocs.comoto.io/platform/contributing.html
function pltfrm-gen-app() {
  local uid
  local gid
  local is_phoenix
  local is_umbrella
  local is_postgres
  local app_name
  local mix_command
  local app_path
  local mix_args=""
  local app_base_path
  local root_path

  uid=$(id -u)
  gid=$(id -g)
  app_name=${PWD##*/}
  app_path=$app_name
  app_base_path=$app_name
  root_path="/opt/"$app_name

  if ! [[ "$app_name" =~ ^[a-z_]*$ ]] ; then
    echo The application name $app_name is invalid. Names can only contain letters and underscores.
    return
  fi

  echo Are you creating a Phoenix application?
  select is_phoenix in "Yes" "No"; do
      case $is_phoenix in
          Yes ) mix_command="phx.new" ; break;;
          No ) mix_command="new" ; break;;
          * ) echo "Invalid Entry"
      esac
  done

  if [ $is_phoenix == "Yes" ] ; then
    echo Is this an umbrella application?
    select is_umbrella in "Yes" "No"; do
       case $is_umbrella in
           Yes )
             app_path=$app_name"_umbrella/"
             mix_args=" --umbrella"
             app_base_path=$app_name"_umbrella"
             break ;;
           No )
             break;;
           * ) echo "Invalid Entry"
       esac
    done

    echo Will you be using Postgres?
    select is_postgres in "Yes" "No"; do
       case $is_postgres in
           Yes ) break;;
           No )  mix_args=$mix_args" --no-ecto" ; break;;
           * ) echo "Invalid Entry"
       esac
    done
  fi

  # The below:
  # - creates a temporary docker container with your folder mounted inside
  # - runs either `mix new` or `mix phx.new`. This is going to create a subfolder inside your folder for the app.
  # - uses perl to inject our platform package as dependency to the new project's mix file
  # - runs the app generator that comes with the platform package (mix pltfrm.gen.app), see that repo for more info
  # - moves everything in the subfolder back out to the top level
  docker run -it \
    -w $root_path \
    -v $PWD:$root_path \
    -v ~/.ssh:/root/.ssh \
    -e IS_PHOENIX=$is_phoenix \
    -e IS_UMBRELLA=$is_umbrella \
    -e IS_POSTGRES=$is_postgres \
    --rm elixir:1.15.8-otp-26-alpine sh -c '
      apk update ;
      apk upgrade ;
      apk add git openssh perl;
      mix local.hex --force ;
      mix local.rebar --force ;
      mix archive.install hex phx_new 1.6.16 --force ;
      mix '"$mix_command$mix_args"' '"$app_name"' ;
      cd '"$app_path"' ;
      perl -i -0pe '"'"'s/defp deps do\n\s*\[/defp deps do\n    [\n      {:platform, git: "git\@github.com:Comoto-Tech\/platform.git"},/'"'"' mix.exs ;
      mix deps.get ;
      mix pltfrm.gen.app ;
      cd '"$root_path"' ;
      chown '"$uid"':'"$gid"' '"$app_base_path"'/ -R ;
      mv '"$app_base_path"'/* . ;
      mv '"$app_base_path"'/.[!.]* . ;
      rm -rf '"$app_base_path"'
    '
}

function ecom-generate-test-seed() {
  ecom-load-test-schema;
  ecom-bash 'RAILS_ENV=test rake db:test:generate_seed';
}

alias frmt=${PROJECT_ROOT}/monorepo/zlaverse/support/frmt.sh
alias docker-compose="docker compose"

function check_product_search_service_index() {
  msg="Run 'product-search-service-full-index' to create your index"

  result=`curl http://localhost:9201/_cat/indices | grep " products "`
  if [ "$result" != "" ]; then
    curl -X DELETE http://localhost:9201/products
    echo ""
    echo "Wrongly named index found and deleted"
    echo $msg
  else
    result=`curl http://localhost:9201/_cat/indices`
    if [ "$result" = "" ]; then
      echo ""
      echo "You have no Product Search Service index"
      echo $msg
    else
      echo "Looking good!"
    fi
  fi
}

# Docker compose up with optional container logging
# Usage: dup [service_name_pattern]
# Example: dup, dup rz, dup cg, dup jp
# Default: rz (revzilla-redline-webapp if no argument provided)
# Shortcuts: rz=revzilla-redline-webapp, cg=cycle-gear-redline-webapp, jp=jp-cycles-redline-webapp
function dup() {
  local pattern="${1:-rz}"
  local service=""
  local is_shortcut=false

  # Apply shortcuts - these are exact service names, no further searching needed
  case "$pattern" in
    rz)
      service="revzilla-redline-webapp"
      is_shortcut=true
      ;;
    cg)
      service="cycle-gear-redline-webapp"
      is_shortcut=true
      ;;
    jp)
      service="jp-cycles-redline-webapp"
      is_shortcut=true
      ;;
  esac

  # If not a shortcut, search for the pattern
  if [ "$is_shortcut" = false ]; then
    # First try with -redline-webapp suffix
    service=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "${pattern}-redline-webapp" | head -n 1)

    # If no redline-webapp match, try general pattern
    if [ -z "$service" ]; then
      service=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "$pattern" | head -n 1)
    fi
  fi

  (cd $COMPOSE_ROOT && docker compose up -d)

  if [ -n "$service" ]; then
    echo "Following logs for: $service"
    (cd $COMPOSE_ROOT && docker compose logs --tail=10 -f "$service")
  else
    echo "No running service found matching pattern: $pattern"
    echo "Available services:"
    (cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}')
  fi
}

# Docker compose restart with optional container logging
# Usage: drestart [service_name_pattern]
# Example: drestart (restarts all), drestart rz, drestart cg, drestart jp
# Default: restarts all containers if no argument provided
# Shortcuts: rz=revzilla-redline-webapp, cg=cycle-gear-redline-webapp, jp=jp-cycles-redline-webapp
function drestart() {
  local pattern="$1"
  local service=""
  local is_shortcut=false

  # If no argument provided, restart all containers
  if [ -z "$pattern" ]; then
    echo "Restarting all containers..."
    (cd $COMPOSE_ROOT && docker compose restart)
    return 0
  fi

  # Apply shortcuts - these are exact service names, no further searching needed
  case "$pattern" in
    rz)
      service="revzilla-redline-webapp"
      is_shortcut=true
      ;;
    cg)
      service="cycle-gear-redline-webapp"
      is_shortcut=true
      ;;
    jp)
      service="jp-cycles-redline-webapp"
      is_shortcut=true
      ;;
  esac

  # If not a shortcut, search for the pattern
  if [ "$is_shortcut" = false ]; then
    # First try with -redline-webapp suffix
    service=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "${pattern}-redline-webapp" | head -n 1)

    # If no redline-webapp match, try general pattern
    if [ -z "$service" ]; then
      service=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "$pattern" | head -n 1)
    fi
  fi

  if [ -n "$service" ]; then
    echo "Restarting: $service"
    (cd $COMPOSE_ROOT && docker compose restart "$service")
    echo "Following logs for: $service"
    (cd $COMPOSE_ROOT && docker compose logs --tail=10 -f "$service")
  else
    echo "No running service found matching pattern: $pattern"
    echo "Available services:"
    (cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}')
  fi
}




# Docker compose logs with optional grep filtering and support for multiple containers
# Usage: dlog [service_name_pattern] [grep_pattern]
# Example: dlog, dlog rz, dlog cg "error", dlog postgres
# Default: rz (revzilla-redline-webapp if no argument provided)
# Shortcuts: rz=revzilla-redline-webapp, cg=cycle-gear-redline-webapp, jp=jp-cycles-redline-webapp
# Note: Can follow logs from multiple matching containers simultaneously
function dlog() {
  local pattern="${1:-rz}"
  local grep_pattern="$2"
  local services=()
  local is_shortcut=false

  # Apply shortcuts - these are exact service names, no further searching needed
  case "$pattern" in
    rz)
      services=("revzilla-redline-webapp")
      is_shortcut=true
      ;;
    cg)
      services=("cycle-gear-redline-webapp")
      is_shortcut=true
      ;;
    jp)
      services=("jp-cycles-redline-webapp")
      is_shortcut=true
      ;;
  esac

  # If not a shortcut, search for the pattern and collect ALL matches
  if [ "$is_shortcut" = false ]; then
    # First try with -redline-webapp suffix
    local webapp_matches=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "${pattern}-redline-webapp")
    
    if [ -n "$webapp_matches" ]; then
      # Convert newline-separated matches to array
      while IFS= read -r line; do
        services+=("$line")
      done <<< "$webapp_matches"
    else
      # If no redline-webapp match, try general pattern
      local general_matches=$(cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}' | grep "$pattern")
      
      if [ -n "$general_matches" ]; then
        while IFS= read -r line; do
          services+=("$line")
        done <<< "$general_matches"
      fi
    fi
  fi

  if [ ${#services[@]} -gt 0 ]; then
    if [ ${#services[@]} -eq 1 ]; then
      echo "Following logs for: ${services[0]}"
    else
      echo "Following logs for ${#services[@]} services: ${services[*]}"
    fi
    
    if [ -n "$grep_pattern" ]; then
      echo "Filtering for: $grep_pattern"
      (cd $COMPOSE_ROOT && docker compose logs --tail=10 -f "${services[@]}" | grep --color=auto "$grep_pattern")
    else
      (cd $COMPOSE_ROOT && docker compose logs --tail=10 -f "${services[@]}")
    fi
  else
    echo "No running service found matching pattern: $pattern"
    echo "Available services:"
    (cd $COMPOSE_ROOT && docker compose ps --format '{{.Service}}')
  fi
}

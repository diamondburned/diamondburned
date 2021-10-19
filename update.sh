#!/usr/bin/env bash
set -e

username="diamondburned"
in="README.tmpl.md"
out="README.md"

main() {
	# Dependencies.
	require curl jq sort uniq

	# Require the metrics token for API querying.
	[[ "$METRICS_TOKEN" ]] || fatal 'missing $METRICS_TOKEN'

	reposJSON=()
	reposPage=0
	for ((;;)); {
		last=1
		while read -r json; do
			reposJSON+=( "$json" )
			last=0
		done < <(queryGitHub "/user/repos?per_page=100&page=$reposPage" | jq -c '.[]')

		# Out of pages. Break.
		(( last == 1 )) && break
		# Not out of pages. Continue.
		(( reposPage++ )) && continue
	}

	publicReposJSON=$(printf "%s\n" "${reposJSON[@]}" | jq -c "select((.private | not ) and (.fork | not))")

	render > "$out"
}

# nPublicRepos ($publicReposJSON)
nPublicRepos() {
	echo -n "$publicReposJSON" | jq -s 'length'
}

# nStargazers ($publicReposJSON)
nStargazers() {
	echo -n "$publicReposJSON" | jq -n '[inputs.stargazers_count] | add'
}

# repoLanguages ($publicReposJSON)
repoLanguages() {
	echo -n "$publicReposJSON"                         \
		| jq -rn 'inputs.language | select(. != null)' \
		| sort | uniq -c | sort -nr                    \
		| topUnique 3
}

# repoLicenses ($publicReposJSON)
repoLicenses() {
	echo -n "$publicReposJSON"                             \
		| jq -rn 'inputs.license.name | select(. != null)' \
		| sort | uniq -c | sort -nr                        \
		| topUnique 3
}

# topUnique numUnique < uniqOutput
topUnique() {
	numUnique="${1:- 0}"
	(( numUnique < 1 )) && return 1

	readarray -d $'\n' lines

	nrepos=$(nPublicRepos)
	top=()
	sum=0

	for line in "${lines[@]}"; {
		[[ "$line" =~ \ *([0-9]+)\ ([A-Za-z0-9 ]+) ]] && {
			local count=${BASH_REMATCH[1]}
			local item=${BASH_REMATCH[2]}

			local percentage=$[ count * 100 / nrepos ]
			top+=( "$item ($percentage%)" )

			(( sum += percentage )) || true # (()) is weird.
			(( ${#top[@]} == numUnique )) && break
		}
	}

	(( sum == 0 )) && return 0

	printf "%s, " "${top[@]}"
	echo -n "and others ($[100-sum]%)"
}

render() {
	local render="$(mktemp)"

	(
		echo "cat << __EOF__"
		cat "$in"
		echo "__EOF__"
	) > "$render"

	. "$render"

	rm "$render"
}

fatal() {
	echo Fatal: "$@" 1>&2
	exit 1
}

require() {
	for dep in "$@"; {
		command -v &> /dev/null || fatal "missing $dep"
	}
}

# GETGitHub path...
# queryGitHub GETs a GitHub REST API path.
queryGitHub() {
	httpGET \
		-H "Accept: application/vnd.github.v3+json" \
		-H "Authorization: token $METRICS_TOKEN"    \
		"https://api.github.com$1"
}

# GET url...
httpGET() {
	curl -X GET -f -s "$@"
}

main "$@"

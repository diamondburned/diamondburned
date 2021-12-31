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
		done < <(queryGitHub "/user/repos?per_page=100&page=$reposPage&type=public" | jq -c '.[]')

		# Out of pages. Break.
		(( last == 1 )) && break
		# Not out of pages. Continue.
		(( reposPage++ )) && continue
	}

	publicReposJSON=$(printf "%s\n" "${reposJSON[@]}" | jq -c "select((.private | not ) and (.fork | not))")

	render > "$out"
	saveCSV "data/stargazers.csv" "$(nStargazers)"

	# This does virtually nothing, but hopefully we can improve it to be better
	# in the future. For now, just remove the faulty record manually.
	movingAverage "data/stargazers.csv" 4 \
		| renderSVG "-7 days" gold        \
		> sparklines/stargazers.svg
}

# saveCSV filepath value
# saveCSV saves the given value into the file but only if the value differs.
saveCSV() {
	local filepath="$1"
	local value="$2"
	local ts=""

	{
		# Get the last line of the CSV file.
		record="$(tail -n1 "$filepath" 2> /dev/null)"
		# Get the last column, which is the value, and compare it with the
		# current value. Succeed if the value is the same.
		[[ "${record##*,}" == "$value" ]]
	} || {
		# Ensure target directory exists.
		mkdir -p "$(dirname "$filepath")"
		# Value is not the same or the value doesn't exist. Add the record.
		printf -v ts "%(%s)T"
		printf "%d,%d\n" "$ts" "$value" >> "$filepath"
	}
}

# movingAverage "/path/to/data.csv" "n-window" y=$[ (gap - (v - min)) * h / gap ]
movingAverage() {
	local path="$1"
	local n="$2"

	readarray -d $'\n' rows < "$path"

	# Don't process if we have less records than the size of the window.
	(( ${#rows[@]} < n )) && {
		printf "%s\n" "${rows[@]}"
		return
	}

	window=()
	for row in "${rows[@]}"; {
		IFS=, values=( $row )
		local t="${values[0]}"
		local v="${values[1]}"

		window+=( "$v" )

		(( ${#window[@]} <= n )) && {
			continue
		}

		# Pop off the first entry.
		window=( "${window[@]:1}" )

		# Average out the window.
		local avg=0
		for value in "${window[@]}"; {
			avg=$[ avg + value ]
		}
		avg=$[ avg / ${#window[@]} ]

		# Print record
		echo "$t,$avg"
	}
}

# renderSVG "date" "color" < stdin
# renderSVG renders an SVG graph of the given CSV file. The CSV file must have 2
# columns, 1st being Unix epoch date and 2nd being the raw value.
renderSVG() {
	local date="$1"
	local color="$2"

	local w=65
	local h=10
	local m=100 # multiples for accuracy; beware of epoch overflow

	w=$[ w * m ]
	h=$[ h * m ]

	cat << EOL
<svg xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 $w $h">
EOL

	readarray -d $'\n' rows

	# Find the minimum and maximum values.
	local min=
	local max=
	local gap=

	# startAt and endAt are in epoch.
	endAt=$(echo -n "${rows[-1]}" | cut -d, -f1)
	startAt=$(date -d "$(date -d "@$endAt") -7 days" +%s)

	for row in "${rows[@]}"; {
		# Parse the row into an array of values delimited by a comma.
		IFS=, values=( $row )
		local t="${values[0]}"
		local v="${values[1]}"

		# If the datapoint is outside the time range, then skip it.
		(( t < startAt )) && continue

		(( v > max )) || [[ ! "$max" ]] && max=$v
		(( v < min )) || [[ ! "$min" ]] && min=$v
	}

	# Deal with the inaccurate integer math by scaling up the values.
	min=$[ min * m ]
	max=$[ max * m ]
	# Add a bit of headroom (5% or 20/100 parts extra) for the max value.
	max=$[ max + (max / (20 * m)) ]
	# Do a bit more (10% or 10/100) for the min value.
	min=$[ min - (min / (10 * m)) ]
	# gap is the difference between the minimum and maximum value.
	gap=$[ max - min ]

	printf '\t'
	printf '<path fill="none" stroke="%s" stroke-width="125" stroke-linecap="round" stroke-linejoin="round" d="' "$color"

	local drew=

	for row in "${rows[@]}"; {
		IFS=, values=( $row )
		local t="${values[0]}"
		local v="${values[1]}"

		# Calculate the time instant if the startAt were to be the starting
		# point.
		t=$[ t - startAt ]

		# Scale the value up.
		v=$[ v * m ]

		x=$[ t * w / (endAt - startAt) ]
		y=$[ (gap - (v - min)) * h / gap ]

		# Draw the first move command if we haven't.
		[[ ! $drew ]] && {
			printf 'M0 %d ' "$y"
			drew=1
		}

		printf ' L%d %d' "$x" "$y"
	}

	echo '" />'
	echo '</svg>'
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
		| jq -rn 'inputs.license.spdx_id | select(. != null)' \
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

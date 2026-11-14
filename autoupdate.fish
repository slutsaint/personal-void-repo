#!/usr/bin/env fish

set updates

# API base; only overridden by tests, so they can talk to a local fake server
if not set -q GITHUB_API
    set GITHUB_API https://api.github.com
end

# Set when any upstream check could not be completed. The run is then marked
# failed at the end, instead of looking green while nothing was checked.
set failed

function get_current_version -a pkg_name
    cat ./pkgs/$pkg_name/template | grep "version=" | cut -c 9-
end

function get_current_revision -a pkg_name
    cat ./pkgs/$pkg_name/template | grep "revision=" | cut -c 10-
end

function get_github_newest_tag_version -a repo pattern
    # --fail: an HTTP error (rate limit, 5xx) is an error, not data. Retried a few times.
    curl -fsS --retry 4 --retry-delay 5 --retry-all-errors \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "$GITHUB_API/repos/$repo/tags?per_page=100" |
        jq -sr --arg pattern "$pattern" '.[] | map(.name) | map(select(test($pattern))) | sort_by(match($pattern).captures | first | .string | split(".") | map(tonumber)) | reverse | first | match($pattern).captures | first | .string'
end

function get_github_newest_commit_at_midnight -a repo branch
    set date $(TZ='Etc/UTC' date --iso-8601)
    set midnight $date"T00:00.00Z"
    curl -s \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accepts: application/github+json" \
        "https://api.github.com/repos/$repo/commits?sha=$branch&until=$midnight&per_page=1"
end

function extract_upstream_version -a repo sha version_file version_pattern version_file_preprocessing
    if test -z "$version_file_preprocessing"
        set version_file_preprocessing cat
    end
    curl -s \
            "https://raw.githubusercontent.com/$repo/$sha/$version_file" |
        sh -c "$version_file_preprocessing" |
        sed -nE "s/$version_pattern/\\1/p" |
        head -n1
end

function get_digest -a url
    # Never hash an error page: a failed or empty download returns an error and prints nothing.
    set -l tmp $(mktemp)
    if not curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors -o "$tmp" "$url"; or not test -s "$tmp"
        rm -f "$tmp"
        return 1
    end
    sha256sum "$tmp" | cut -d " " -f 1
    rm -f "$tmp"
end

function check_github_tagged_updates -a repo pkg_name pattern
    echo "Checking for updates for $pkg_name"
    set current_version $(get_current_version $pkg_name)
    set latest_version $(get_github_newest_tag_version $repo $pattern)
    if test -z "$latest_version"
        echo "Error finding latest version"
        set -g failed 1
        return
    end
    if test "$latest_version" = "$current_version"
        echo "No update found"
        return
    end
    echo "Update found: $latest_version"
    set dist_files $(cat ./pkgs/$pkg_name/template | sed -nE "s/distfiles=\"(.*)\"/\1/p" | sed "s/\${version}/$latest_version/")
    set digest $(get_digest $dist_files)
    if test -z "$digest"
        echo "Error: could not download $dist_files, template left unchanged"
        set -g failed 1
        return
    end
    sed -i "s/version=.*/version=$latest_version/" ./pkgs/$pkg_name/template
    sed -i "s/checksum=.*/checksum=\"$digest\"/" ./pkgs/$pkg_name/template
    sed -i "s/^revision=.*/revision=1/" ./pkgs/$pkg_name/template
    set -a updates "$pkg_name=$latest_version"
end

function check_github_nightly_updates -a repo pkg_name branch version_file version_pattern version_file_preprocessing
    echo "Checking for updates for $pkg_name"
    set current_version $(get_current_version $pkg_name)
    set commit $(get_github_newest_commit_at_midnight $repo $branch)
    set commit_date $(echo "$commit" | jq -r '.[0].commit.committer.date | split("T") | first' | sed 's/-/./g')
    set commit_hash $(echo "$commit" | jq -r '.[0].sha')
    set upstream_version $(extract_upstream_version $repo $commit_hash $version_file $version_pattern $version_file_preprocessing)
    if test -z "$upstream_version"
        echo "Error finding upstream version"
        return
    end
    set latest_version "$upstream_version.$commit_date"
    if test "$latest_version" = "$current_version"
        echo "No update found"
        return
    end
    echo "Update found: $latest_version"
    set dist_files "https://github.com/$repo/archive/$commit_hash.tar.gz"
    set digest $(get_digest $dist_files)
    if test -z "$digest"
        echo "Error: could not download $dist_files, template left unchanged"
        set -g failed 1
        return
    end
    set dist_files_escaped $(echo "$dist_files" | sed 's|/|\\\/|g')
    sed -i "s/version=.*/version=$latest_version/" ./pkgs/$pkg_name/template
    sed -i "s/distfiles=.*/distfiles=\"$dist_files_escaped\"/" ./pkgs/$pkg_name/template
    sed -i "s/checksum=.*/checksum=\"$digest\"/" ./pkgs/$pkg_name/template
    sed -i "s/revision=.*/revision=1/" ./pkgs/$pkg_name/template
    sed -i "s/revision \".*\"/revision \"$commit_hash\"/" ./pkgs/$pkg_name/template
    set -a updates "$pkg_name=$latest_version"
end

function update_shlibs -a shlib pkg_name subproject_name 
    set current_version $(get_current_version $pkg_name)
    set current_revision $(get_current_revision $pkg_name)
    
    if test -z "$subproject_name"
        set subproject_name $pkg_name
    end

    set pkg_ref "$subproject_name"-"$current_version"_"$current_revision"
    set new_shlib_line "$shlib $pkg_ref"
    set shlib_escaped $(echo "$shlib" | sed 's|\.|\\\.|g')
    sed -i "s/$shlib_escaped .*/$new_shlib_line/" ./common/shlibs
end

function update_provides -a pkg_name provides
    sed -i "s/provides=.*/provides=\"$provides\"/" ./pkgs/$pkg_name/template
end


check_github_tagged_updates noctalia-dev/noctalia noctalia '^v([0-9]+\.[0-9]+\.[0-9]+)$'
check_github_tagged_updates noctalia-dev/noctalia-greeter noctalia-greeter '^v([0-9]+\.[0-9]+\.[0-9]+)$'
check_github_tagged_updates pankaspe/nordend-fm nordend '^v([0-9]+\.[0-9]+\.[0-9]+)$'

if test -n "$updates"
    set output_lines "updates<<STRING" $updates "STRING"
    string join \n $output_lines >> $GITHUB_OUTPUT
end

# Any updates found are still committed and built; the workflow then fails the
# run in its last step so a broken check is visible.
if test -n "$failed"
    echo "failed=1" >> $GITHUB_OUTPUT
end
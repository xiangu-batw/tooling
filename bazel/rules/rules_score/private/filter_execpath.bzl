# *******************************************************************************
# Copyright (c) 2026 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************
"""Rule for filtering execpaths files from a target's output and adapting the matching path.
Currently using this rule to resolve the input path for breathe's doxygen XML input.
"""

load("//bazel/rules/rules_score:providers.bzl", "FilteredExecpathInfo")

def _filter_execpath_impl(ctx):
    """Implementation of the filter_execpath rule.
    Iterates over the output files of the target, finds the one matching
    filter_pattern, and computes the resolved path suffix after /bin/.
    """
    target = ctx.attr.target
    filter_pattern = ctx.attr.filter_pattern
    flag = ctx.attr.flag

    # Get all output files from the target
    files = target[DefaultInfo].files.to_list()

    # Filter for the path matching the filter pattern
    matched_file = None
    for f in files:
        if filter_pattern in f.path:
            matched_file = f
            break
    if not matched_file:
        all_paths = [f.path for f in files]
        fail("filter_execpath: no path matching '{}' found in outputs of {}. Available paths: {}".format(
            filter_pattern,
            target.label,
            ", ".join(all_paths),
        ))

    # Strip the Bazel bin directory prefix from the matched path to get the path
    # relative to the output base. Since _relocate() in sphinx_module symlinks
    # source files under <source_prefix>/<original_path>, the relocated file lives
    # at <source_dir>/<suffix_part> where source_dir is the Sphinx source directory.
    # Breathe resolves breathe_projects paths relative to source_dir (app.srcdir),
    # so we must return just the suffix_part.
    matched_path = matched_file.path
    bin_dir_prefix = ctx.bin_dir.path + "/"
    if matched_path.startswith(bin_dir_prefix):
        suffix_part = matched_path[len(bin_dir_prefix):]
    else:
        suffix_part = matched_path
    resolved_arg = flag + "=" + suffix_part
    return [
        DefaultInfo(files = depset([matched_file])),
        FilteredExecpathInfo(
            flag = flag,
            resolved_path = suffix_part,
            arg = resolved_arg,
            matched_file = matched_file,
        ),
    ]

_filter_execpath_rule = rule(
    implementation = _filter_execpath_impl,
    attrs = {
        "flag": attr.string(
            mandatory = True,
            doc = "The Sphinx -D flag prefix (e.g. '-Dbreathe_projects.com').",
        ),
        "target": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "The Bazel target whose output files to search.",
        ),
        "filter_pattern": attr.string(
            mandatory = True,
            doc = "Substring to match when filtering the target's output file paths (e.g. 'doxygen_build/xml').",
        ),
    },
    doc = """Resolve and filter an execpath from a target's outputs at analysis time.
    This rule finds the output file from `target` whose path contains
    `filter_pattern`, strips the Bazel bin directory prefix, and provides
    the result as a FilteredExecpathInfo for consumption by sphinx_module.
    Example usage in BUILD:
        load("@score_tooling//bazel/rules/rules_score:rules_score.bzl", "filter_execpath", "sphinx_module")
        filter_execpath(
            name = "breathe_doxygen_xml",
            flag = "-Dbreathe_projects.doxygen_build",
            target = "//docs/sphinx:doxygen_xml",
            filter_pattern = "doxygen_build/xml",
        )
        sphinx_module(
            name = "sphinx_doc",
            extra_opts_targets = [":breathe_doxygen_xml"],
            extra_opts = ["-Dbreathe_default_project=doxygen_build"],
            ...
        )
    """,
)

def filter_execpath(name, flag, target, filter_pattern, **kwargs):
    """Resolve and filter an execpath from a target's outputs at analysis time.
    Args:
        name: Name for this target.
        flag: The Sphinx -D flag prefix (e.g. "-Dbreathe_projects.doxygen_build").
        target: The Bazel label whose output files to search.
        filter_pattern: Substring to match when filtering the target's output file paths.
        **kwargs: Additional keyword arguments passed to the underlying rule (e.g. visibility).
    """
    _filter_execpath_rule(
        name = name,
        flag = flag,
        target = target,
        filter_pattern = filter_pattern,
        **kwargs
    )

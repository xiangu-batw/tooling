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

# ======================================================================================
# Helpers
# ======================================================================================
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_python//sphinxdocs:sphinx_docs_library.bzl", "sphinx_docs_library")
load("@rules_python//sphinxdocs/private:sphinx_docs_library_info.bzl", "SphinxDocsLibraryInfo")
load("//bazel/rules/rules_score:providers.bzl", "SphinxModuleInfo", "SphinxNeedsInfo")

# Delimiter used to encode filter_execpath parameters into a single extra_opts string.
_FILTER_EXECPATH_DELIM = "@@FILTER_EXECPATH@@"

def filter_execpath(flag, label, filter_pattern):
    """Construct an extra_opts entry that filters execpaths and rewrites them with the relocated target prefix.

    When used in extra_opts of sphinx_module, the rule implementation will:
    1. Expand $(execpaths <label>) to get all output paths
    2. Filter for the path containing <filter_pattern>
    3. Rewrite the path to include the target's relocated prefix
       (e.g. bazel-out/.../bin/<package>/<name>/<original_path>)

    Example usage in BUILD:
        load("@score_tooling//bazel/rules/rules_score:rules_score.bzl", "filter_execpath", "sphinx_module")

        sphinx_module(
            name = "sphinx_doc",
            extra_opts = [
                filter_execpath("-Dbreathe_projects.com", "//docs/sphinx:doxygen_xml", "doxygen_build/xml"),
            ],
            ...
        )

    Args:
        flag: The Sphinx -D flag prefix (e.g. "-Dbreathe_projects.com")
        label: The Bazel label whose execpaths to expand (e.g. "//docs/sphinx:doxygen_xml")
        filter_pattern: Substring to match when filtering the execpaths (e.g. "doxygen_build/xml")

    Returns:
        A specially formatted string that the sphinx_module rule will process.
    """
    return _FILTER_EXECPATH_DELIM.join([flag, str(label), filter_pattern])

def _create_config_py(ctx):
    """Get or generate the conf.py configuration file.

    Args:
        ctx: Rule context
    """
    sphinx_toolchain = ctx.toolchains["//bazel/rules/rules_score:toolchain_type"].sphinxinfo
    config_file = ctx.actions.declare_file(ctx.label.name + "/conf.py")
    template = sphinx_toolchain.conf_template.files.to_list()[0]

    # Read template and substitute PROJECT_NAME
    ctx.actions.expand_template(
        template = template,
        output = config_file,
        substitutions = {
            "{PROJECT_NAME}": ctx.label.name.replace("_", " ").title(),
        },
    )
    return config_file

# ======================================================================================
# Common attributes for Sphinx rules
# ======================================================================================
sphinx_rule_attrs = {
    "srcs": attr.label_list(
        allow_files = True,
        doc = "List of source files for the Sphinx documentation.",
    ),
    "index": attr.label(
        allow_files = [".rst"],
        doc = "Index file (index.rst) for the Sphinx documentation.",
        mandatory = True,
    ),
    "deps": attr.label_list(
        doc = "List of other sphinx_module targets this module depends on for intersphinx.",
    ),
}

# ======================================================================================
# Rule implementations
# ======================================================================================
def _score_needs_impl(ctx):
    sphinx_toolchain = ctx.toolchains["//bazel/rules/rules_score:toolchain_type"].sphinxinfo
    output_path = ctx.label.name.replace("_needs", "") + "/needs.json"
    needs_output = ctx.actions.declare_file(output_path)

    # Get config file (generate or use provided)
    config_file = _create_config_py(ctx)

    # Phase 1: Build needs.json (without external needs)
    needs_inputs = ctx.files.srcs + [config_file]

    needs_args = [
        "--index_file",
        ctx.attr.index.files.to_list()[0].path,
        "--output_dir",
        needs_output.dirname,
        "--config",
        config_file.path,
        "--builder",
        "needs",
    ]

    ctx.actions.run(
        inputs = needs_inputs,
        outputs = [needs_output],
        arguments = needs_args,
        progress_message = "Generating needs.json for: %s" % ctx.label.name,
        executable = sphinx_toolchain.sphinx.files_to_run.executable,
        tools = [
            sphinx_toolchain.sphinx.files_to_run,
        ],
    )

    transitive_needs = [dep[SphinxNeedsInfo].needs_json_files for dep in ctx.attr.deps if SphinxNeedsInfo in dep]
    needs_json_files = depset([needs_output], transitive = transitive_needs)

    return [
        DefaultInfo(
            files = needs_json_files,
        ),
        SphinxNeedsInfo(
            needs_json_file = needs_output,  # Direct file only
            needs_json_files = needs_json_files,  # Transitive depset
        ),
    ]

def _score_html_impl(ctx):
    """Implementation for building a Sphinx module with two-phase build.

    Phase 1: Generate needs.json for this module and collect from all deps
    Phase 2: Generate HTML with external needs and merge all dependency HTML
    """

    run_args = []  # Copy of the args to forward along to debug runner
    args = ctx.actions.args()  # Args passed to the action

    # Expand location references in extra_opts and collect as sphinx arguments.
    # targets must include all labels referenced via $(location ...) / $(execpaths ...).
    extra_opts_targets = ctx.attr.srcs + ctx.attr.docs_library_deps
    source_prefix = ctx.label.name

    for opt in ctx.attr.extra_opts:
        if _FILTER_EXECPATH_DELIM in opt:
            # Process filter_execpath() encoded strings:
            # Format: flag@@FILTER_EXECPATH@@label@@FILTER_EXECPATH@@filter_pattern
            parts = opt.split(_FILTER_EXECPATH_DELIM)
            flag = parts[0]
            label_str = parts[1]
            filter_pattern = parts[2]

            # Expand execpaths for the referenced label
            expanded = ctx.expand_location("$(execpaths " + label_str + ")", targets = extra_opts_targets)
            expanded_paths = expanded.split(" ")

            # Filter for the path matching the filter pattern
            matched_path = None
            for p in expanded_paths:
                if filter_pattern in p:
                    matched_path = p
                    break

            if not matched_path:
                fail("filter_execpath: no path matching '{}' found in execpaths of {}. Paths: {}".format(
                    filter_pattern,
                    label_str,
                    expanded,
                ))

            # Extract the path suffix after "/bin/" — this is the original path relative
            # to the output base. Since _relocate() symlinks source files under
            # <source_prefix>/<original_path>, the relocated file lives at
            # <source_dir>/<suffix_part> where source_dir is the Sphinx source directory.
            # Breathe resolves breathe_projects paths relative to source_dir (app.srcdir),
            # so we must return just the suffix_part.
            bin_marker = "/bin/"
            bin_idx = matched_path.find(bin_marker)
            if bin_idx >= 0:
                suffix_part = matched_path[bin_idx + len(bin_marker):]
            else:
                suffix_part = matched_path

            expanded_opt = flag + "=" + suffix_part
        else:
            # Standard extra_opts: expand locations and pass through
            expanded_opt = ctx.expand_location(opt, targets = extra_opts_targets)

        args.add(expanded_opt)
        run_args.append(expanded_opt)

    # Collect all transitive dependencies with deduplication
    modules = []
    sphinx_toolchain = ctx.toolchains["//bazel/rules/rules_score:toolchain_type"].sphinxinfo
    needs_external_needs = {}
    for dep in ctx.attr.needs:
        if SphinxNeedsInfo in dep:
            dep_name = dep.label.name.replace("_needs", "")
            needs_external_needs[dep.label.name] = {
                "base_url": dep_name,  # Relative path to the subdirectory where dep HTML is copied
                "json_path": dep[SphinxNeedsInfo].needs_json_file.path,  # Use direct file
                "id_prefix": "",
                "css_class": "",
            }

    for dep in ctx.attr.deps:
        if SphinxModuleInfo in dep:
            modules.extend([dep[SphinxModuleInfo].html_dir])

    needs_external_needs_json = ctx.actions.declare_file(ctx.label.name + "/needs_external_needs.json")

    ctx.actions.write(
        output = needs_external_needs_json,
        content = json.encode_indent(needs_external_needs, indent = "  "),
    )

    sphinx_source_files = []

    # Materialize a file under the `_sources` dir
    def _relocate(source_file, dest_path = None):
        if not dest_path:
            dest_path = source_file.short_path.removeprefix(ctx.attr.strip_prefix)

        dest_path = paths.join(source_prefix, dest_path)
        if source_file.is_directory:
            dest_file = ctx.actions.declare_directory(dest_path)
        else:
            dest_file = ctx.actions.declare_file(dest_path)
        ctx.actions.symlink(
            output = dest_file,
            target_file = source_file,
            progress_message = "Symlinking Sphinx source %{input} to %{output}",
        )
        sphinx_source_files.append(dest_file)
        return dest_file

    for dep in ctx.attr.deps:
        if SphinxModuleInfo in dep:
            modules.extend([dep[SphinxModuleInfo].html_dir])

    for t in ctx.attr.docs_library_deps:
        info = t[SphinxDocsLibraryInfo]
        for entry in info.transitive.to_list():
            for original in entry.files:
                new_path = entry.prefix + original.short_path.removeprefix(entry.strip_prefix)
                _relocate(original, new_path)

    config_file = _create_config_py(ctx)

    # Sphinx only accepts a single directory to read its doc sources from.
    # Because plain files and generated files are in different directories,
    # we need to merge the two into a single directory.
    for orig_file in ctx.files.srcs:
        _relocate(orig_file)

    relocated_index_file = ""
    for input_file in sphinx_source_files:
        if input_file.path.endswith("/index.rst"):
            relocated_index_file = input_file.path

    # Build HTML with external needs
    html_inputs = sphinx_source_files + ctx.files.needs + [config_file, needs_external_needs_json]
    sphinx_html_output = ctx.actions.declare_directory(ctx.label.name + "/_html")
    html_args = [
        "--index_file",
        relocated_index_file,
        "--output_dir",
        sphinx_html_output.path,
        "--config",
        config_file.path,
        "--builder",
        "html",
    ]

    ctx.actions.run(
        inputs = html_inputs,
        outputs = [sphinx_html_output],
        arguments = html_args + [args],
        progress_message = "Building HTML: %s" % ctx.label.name,
        executable = sphinx_toolchain.sphinx.files_to_run.executable,
        tools = [
            sphinx_toolchain.sphinx.files_to_run,
        ],
    )

    # Create final HTML output directory with dependencies using Python merge script
    html_output = ctx.actions.declare_directory(ctx.label.name + "/html")

    # Build arguments for the merge script
    merge_args = [
        "--output",
        html_output.path,
        "--main",
        sphinx_html_output.path,
    ]

    merge_inputs = [sphinx_html_output]

    # Add each dependency
    for dep in ctx.attr.deps:
        if SphinxModuleInfo in dep:
            dep_html_dir = dep[SphinxModuleInfo].html_dir
            dep_name = dep.label.name
            merge_inputs.append(dep_html_dir)
            merge_args.extend(["--dep", dep_name + ":" + dep_html_dir.path])

    # Merging html files
    ctx.actions.run(
        inputs = merge_inputs,
        outputs = [html_output],
        arguments = merge_args,
        progress_message = "Merging HTML with dependencies for %s" % ctx.label.name,
        executable = sphinx_toolchain.html_merge_tool.files_to_run.executable,
        tools = [sphinx_toolchain.html_merge_tool.files_to_run],
    )

    return [
        DefaultInfo(files = depset(ctx.files.needs + [html_output])),
        SphinxModuleInfo(
            html_dir = html_output,
        ),
    ]

# ======================================================================================
# Rule definitions
# ======================================================================================

_score_needs = rule(
    implementation = _score_needs_impl,
    attrs = sphinx_rule_attrs,
    toolchains = ["//bazel/rules/rules_score:toolchain_type"],
)

_score_html = rule(
    implementation = _score_html_impl,
    attrs = dict(
        sphinx_rule_attrs,
        strip_prefix = attr.string(doc = "Prefix to remove from input file paths."),
        docs_library_deps = attr.label_list(
            doc = "List of sphinx_docs_library targets to include as source files with prefix/strip_prefix handling.",
        ),
        needs = attr.label_list(
            allow_files = True,
            doc = "Submodule symbols.needs targets for this module.",
        ),
        extra_opts = attr.string_list(
            doc = "Additional options to pass onto Sphinx. These are added after " +
                  "other options, but before the source/output args.",
        ),
    ),
    toolchains = ["//bazel/rules/rules_score:toolchain_type"],
)

# ======================================================================================
# Rule wrappers
# ======================================================================================

def sphinx_module(
        name,
        srcs,
        index,
        deps = [],
        docs_library_deps = [],
        sphinx = Label("//bazel/rules/rules_score:score_build"),
        strip_prefix = "",
        extra_opts = [],
        testonly = False,
        visibility = ["//visibility:public"]):
    """Build a Sphinx module with transitive HTML dependencies.

    This rule builds documentation modules into complete HTML sites with
    transitive dependency collection. All dependencies are automatically
    included in a modules/ subdirectory for intersphinx cross-referencing.

    Args:
        name: Name of the target
        srcs: List of source files (.rst, .md) with index file first
        index: Label to index.rst file
        config: Label to conf.py configuration file (optional, will be auto-generated if not provided)
        deps: List of other sphinx_module targets this module depends on
        docs_library_deps: {type}`list[label]` of {obj}`sphinx_docs_library` targets.
        sphinx: Label to sphinx build binary (default: :sphinx_build)
        strip_prefix: {type}`str` A prefix to remove from the file paths of the
                    source files. e.g., given `//sphinxdocs/docs:foo.md`, stripping `docs/` makes
                    Sphinx see `foo.md` in its generated source directory. If not
                    specified, then {any}`native.package_name` is used.
        extra_opts: {type}`list[str]` Additional options to pass onto Sphinx building.
                    On each provided option, a location expansion is performed.
                    See {any}`ctx.expand_location`.
        visibility: Bazel visibility
    """
    _score_needs(
        name = name + "_needs",
        srcs = srcs,
        index = index,
        deps = [d + "_needs" for d in deps],
        testonly = testonly,
        visibility = visibility,
    )

    _score_html(
        name = name,
        srcs = srcs,
        index = index,
        deps = deps,
        docs_library_deps = docs_library_deps,
        needs = [d + "_needs" for d in deps],
        extra_opts = extra_opts,
        testonly = testonly,
        visibility = visibility,
    )

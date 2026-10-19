#!/usr/bin/env ruby
# PostToolUse hook: validates .yml/.yaml files after Claude writes or edits them.
# Exit 0 = OK (or not a YAML file), exit 2 = problems found (stderr is fed back to Claude).
require "json"
require "yaml"

payload = JSON.parse($stdin.read) rescue {}
path = payload.dig("tool_response", "filePath") || payload.dig("tool_input", "file_path")
exit 0 unless path && path.match?(/\.ya?ml\z/i) && File.file?(path)

errors = []
source = File.read(path)

errors << "file contains tab characters (YAML indentation must use spaces)" if source.match?(/^\t/)

begin
  doc = YAML.safe_load(source, aliases: true, filename: path)

  # Psych silently accepts duplicate keys; walk the AST to catch them.
  walk = lambda do |node|
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |k, _|
        next unless k.is_a?(Psych::Nodes::Scalar)
        if seen[k.value]
          errors << "duplicate key '#{k.value}' at line #{k.start_line + 1} (first at line #{seen[k.value]})"
        else
          seen[k.value] = k.start_line + 1
        end
      end
    end
    node.children&.each { |c| walk.call(c) }
  end
  walk.call(Psych.parse(source, filename: path))

  # Basic structural checks for GitHub Actions workflows.
  if path.include?(".github/workflows/")
    if !doc.is_a?(Hash)
      errors << "workflow must be a mapping at the top level"
    else
      allowed = %w[name run-name on true permissions env defaults concurrency jobs]
      (doc.keys.map(&:to_s) - allowed).each { |k| errors << "unexpected top-level workflow key '#{k}'" }
      errors << "workflow is missing 'on'" unless doc.key?("on") || doc.key?(true)
      jobs = doc["jobs"]
      if !jobs.is_a?(Hash) || jobs.empty?
        errors << "workflow is missing 'jobs'"
      else
        jobs.each do |id, job|
          unless job.is_a?(Hash)
            errors << "job '#{id}' must be a mapping"
            next
          end
          next if job.key?("uses") # reusable workflow call
          errors << "job '#{id}' is missing 'runs-on'" unless job.key?("runs-on")
          steps = job["steps"]
          unless steps.is_a?(Array)
            errors << "job '#{id}' is missing a 'steps' list (check indentation)"
            next
          end
          steps.each_with_index do |step, i|
            if !step.is_a?(Hash)
              errors << "job '#{id}' step #{i + 1} is not a mapping"
            elsif !(step.key?("run") || step.key?("uses"))
              errors << "job '#{id}' step #{i + 1} needs 'run' or 'uses'"
            end
            (step["with"] || {}).each do |k, v|
              errors << "job '#{id}' step #{i + 1}: 'with' entry '#{k}' has no value (missing space after ':'?)" if v.nil? && k.to_s.include?(":")
            end if step.is_a?(Hash) && step["with"].is_a?(Hash)
            if step.is_a?(Hash) && step["with"].is_a?(String)
              errors << "job '#{id}' step #{i + 1}: 'with' is a string, not a mapping (missing space after ':'?)"
            end
          end
        end
      end
    end
  end
rescue Psych::SyntaxError => e
  errors << "YAML syntax error: #{e.message}"
end

exit 0 if errors.empty?
warn "YAML validation failed for #{path}:"
errors.uniq.each { |e| warn "  - #{e}" }
exit 2

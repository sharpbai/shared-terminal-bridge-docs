#!/usr/bin/env ruby
# frozen_string_literal: true

# Normalize block spacing in Markdown exported from Notion so GitHub's GFM
# renderer does not merge headings, lists, quotes, or fenced code into the
# preceding paragraph.

def blank?(line)
  line.strip.empty?
end

def heading?(line)
  line.match?(/^\#{1,6}\s+/)
end

def fence?(line)
  line.match?(/^```/)
end

def quote?(line)
  line.match?(/^>\s?/)
end

def unordered_item?(line)
  line.match?(/^[-*+]\s+/)
end

def ordered_item?(line)
  line.match?(/^\d+\.\s+/)
end

def html_block?(line)
  line.match?(/^<(?:table|details)\b/i)
end

ARGV.each do |path|
  source = File.read(path, encoding: "UTF-8").gsub(/^```plain text\s*$/, "```text")
  lines = source.lines.map(&:rstrip)
  output = []
  in_fence = false

  lines.each do |line|
    if fence?(line)
      output << "" unless output.empty? || blank?(output.last)
      output << line
      in_fence = !in_fence
      output << "" unless in_fence
      next
    end

    if in_fence
      output << line
      next
    end

    if heading?(line)
      output << "" unless output.empty? || blank?(output.last)
      output << line
      output << ""
      next
    end

    if quote?(line)
      output << "" unless output.empty? || blank?(output.last) || quote?(output.last)
    elsif unordered_item?(line)
      output << "" unless output.empty? || blank?(output.last) || unordered_item?(output.last)
    elsif ordered_item?(line)
      output << "" unless output.empty? || blank?(output.last) || ordered_item?(output.last)
    elsif line == "---" || html_block?(line)
      output << "" unless output.empty? || blank?(output.last)
    end

    output << line
  end

  normalized = output.join("\n").gsub(/\n{3,}/, "\n\n").strip + "\n"
  normalized.gsub!(%r{<table\b[\s\S]*?</table>}i) { |table| table.gsub(/\n{2,}/, "\n") }
  normalized.gsub!(%r{<details\b[\s\S]*?</details>}i) { |details| details.gsub(/\n{2,}/, "\n") }
  File.write(path, normalized, mode: "w", encoding: "UTF-8")
end

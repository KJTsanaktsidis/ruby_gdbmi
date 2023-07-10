# frozen_string_literal: true

require 'strscan'

module GDBMI
  class LineBuffer
    def initialize
      @scanner = StringScanner.new(String.new(encoding: Encoding.default_external))
    end

    def <<(data) = @scanner.string << data

    def extract_lines!
      lines = []
      while ln = @scanner.scan(/.*\n/)
          lines << ln
      end
      @scanner.string = @scanner.rest
      lines
    end
  end
end
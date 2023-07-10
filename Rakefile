# frozen_string_literals: true

require 'minitest/test_task'


RESPONSE_PARSER_TAB = 'lib/gdbmi/response_parser.tab.rb'
file RESPONSE_PARSER_TAB => ['lib/gdbmi/response_parser.y'] do |t|
  sh 'racc', '-o', t.name, t.prerequisites.first
end

task :racc => [RESPONSE_PARSER_TAB]
Minitest::TestTask.create

require 'gdbmi'
require 'minitest/autorun'

class TestSessionSettings < Minitest::Test
    def test_debuginfod_enabled
        GDBMI::Session.open do |s|
            s.debuginfod_enabled = false
            refute s.debuginfod_enabled?
            s.debuginfod_enabled = true
            assert s.debuginfod_enabled?

            s.mi_run_raw_console_command('set', 'debuginfod', 'enabled', 'off')
            refute s.debuginfod_enabled?
        end
    end

    def test_autoload_enabled
        GDBMI::Session.open do |s|
            s.auto_load_enabled = false
            refute s.auto_load_enabled?
            s.auto_load_enabled = true
            assert s.auto_load_enabled?

            s.mi_run_raw_console_command('set', 'auto-load', 'off')
            refute s.auto_load_enabled?
        end
    end

    def test_file
        GDBMI::Session.open do |s|
            assert_nil s.file
            s.file = '/bin/sh'
            assert_equal File.realpath('/bin/sh'), s.file

            s.mi_run_raw_console_command('file', '/bin/true')
            assert_equal File.realpath('/bin/true'), s.file
        end
    end

    def test_arguments
        GDBMI::Session.open do |s|
            assert_empty s.arguments
            s.arguments = ['foo', 'bar']
            assert_equal ['foo', 'bar'], s.arguments

            ag = ['foo" with a quote" and space', 'other_arg']
            s.arguments = ag
            assert_equal ag, s.arguments

            s.mi_run_raw_console_command('set', 'args', 'hoge fuge')
            assert_equal ['hoge', 'fuge'], s.arguments
        end
    end

    def test_arguments_with_execution
        GDBMI::Session.open do |s|
            Tempfile.open(['test_arguments_with_execution', '.sh']) do |tf|
                tf.write <<~BASH
                    echo "arg 1: $1"
                    echo "arg 2: $2"
                BASH
                tf.flush

                s.arguments = ['--norc', tf.path, 'foo" with a quote" and space', 'other_arg']
                s.file = '/bin/sh'

                s.run
                # s.wait_for { false }
            end
        end
    end
end

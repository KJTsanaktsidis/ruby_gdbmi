# This gets loaded into the GDB we spawn to define a few extra commands
# (in python) that we need (and can call over GDB/MI).
# One day we could compile GDB against libruby :-)

class RubyMiGetExecFileCmd(gdb.MICommand):
    def __init__(self, name):
        super(RubyMiGetExecFileCmd, self).__init__(name)
    
    def invoke(self, argv):
        v = gdb.current_progspace().filename
        if v is None:
            v = ''
        return { 'value': v }

RubyMiGetExecFileCmd('-ruby-mi-get-exec-file')

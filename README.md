# LDOC

LDOC reads EEP-48 documentation from trusted local BEAM artifacts.

```erlang
'ldoc-beam':'read-docs'("_build/default/lib/my_app/ebin/my_module.beam").
```

The result is `{ok, ModuleDoc}` or a tagged `{error, Reason}` value. This
initial version reads embedded LFE documentation from the explicit artifact
path and does not load the target module.

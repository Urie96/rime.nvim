-- luacheck: ignore 113
---@diagnostic disable: undefined-global
c_module "rimeshim" {
    use_globals = true,
    include "rime_api.h",
    c_source [[
      RimeApi *api;
    ]],
    c_source "module_init_src" [[
      api = rime_get_api();
    ]],
    c_function "get_schema_list" {
        var_out { "<any>", "result" },
        c_source [[
          RimeSchemaList schema_list;
          if (!api->get_schema_list(&schema_list)) {
            fputs("cannot get schema list", stderr);
            return 0;
          }
          lua_newtable(L);
          for (size_t i = 0; i < schema_list.size; i++) {
            lua_createtable(L, 0, 2);
            lua_pushstring(L, schema_list.list[i].schema_id);
            lua_setfield(L, -2, "schema_id");
            lua_pushstring(L, schema_list.list[i].name);
            lua_setfield(L, -2, "name");
            lua_rawseti(L, -2, i + 1);
          }
        ]]
    },
    c_function "start_maintenance" {
        var_in { "bool", "full_check" },
        var_out { "bool", "result" },
        c_source [[
          ${result} = api->start_maintenance(${full_check});
        ]]
    },
    c_function "join_maintenance_thread" {
        c_source [[
          api->join_maintenance_thread();
        ]]
    },
    c_function "is_maintenance_mode" {
        var_out { "bool", "result" },
        c_source [[
          ${result} = api->is_maintenance_mode();
        ]]
    },
    subfiles {
        "src/traits.nobj.lua",
        "src/session.nobj.lua",
    }
}

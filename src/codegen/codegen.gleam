import gleam/list
import gleam/int
import gleam/io
import gleam/dict
import gleam/string
import gleam/option.{type Option, None, Some}
import argv
import gleam/bbmustache as templ
import simplifile
import shellout
import glance
import justin 

const imports_template = "
import gleam/dynamic
import gleam/list
import {{module}}

fn all_errors(result: Result(a, dynamic.DecodeErrors)) -> dynamic.DecodeErrors {
  case result {
    Ok(_) -> []
    Error(errors) -> errors
  }
}
"

const decoder_template = "
pub fn decode_{{type_snake_case}}(
  dyn: dynamic.Dynamic,
) -> Result(discord.{{type_name}}, dynamic.DecodeErrors) {
  case
    {{#fields}}{{func_name}}(\"{{key}}\", {{value}})(dyn){{comma}}{{/fields}}
  {
    {{#fields}}Ok({{index}}){{comma}}{{/fields}} ->
     Ok(discord.{{type_name}}({{#fields}}{{index}}{{comma}}{{/fields}}
    ))
     {{#fields}}{{index}}{{comma}}{{/fields}} ->
      Error(list.concat([
        {{#fields}}all_errors({{index}}){{comma}}{{/fields}}
      ]))
  }
}
"

pub fn main() {
  case simplifile.verify_is_file("./gleam.toml") {
    Ok(exists) if exists == True -> Nil
    _ -> panic as "not in project root"
  }

  let assert Args(..) as args = parse_args(argv.load().arguments)
  let assert Ok(source) =
    simplifile.read("../src/" <> args.import_module <> ".gleam")
  let assert Ok(module) = glance.module(source)

  let output_path = args.out_file

  case simplifile.delete(output_path) {
    Ok(_) -> Nil
    Error(simplifile.Enoent) -> Nil
    _ -> panic as "cannot delete a old file"
  }

  let rendered =
    do_template(imports_template, [
      #("module", templ.string(args.import_module)),
    ])
  let assert Ok(_) = simplifile.write(to: output_path, contents: rendered)

  list.each(args.types, fn(type_name) {
    io.debug("looking for the type: " <> type_name)
    let assert Ok(found) =
      module.custom_types
      |> list.find(fn(x) { x.definition.name == type_name })
    let assert Ok(first_variant) =
      found.definition.variants
      |> list.at(0)

    let fields_decoders = get_fields(first_variant.fields)
    let rendered = generate(type_name, fields_decoders)

    let assert Ok(_) = simplifile.append(to: output_path, contents: rendered)
  })

  io.debug("formatting...")

  let assert Ok(_) =
    shellout.command(run: "gleam", in: ".", with: ["format", output_path], opt: [
      shellout.LetBeStdout,
    ])
}

fn get_fields(fields: List(glance.Field(glance.Type))) -> List(FieldDecoder) {
  case fields {
    [field, ..fields] -> {
      [convert_type_to_decoder(field), ..get_fields(fields)]
    }
    [] -> []
  }
}

pub type FieldDecoder {
  Field(name: String, arg: String)
  OptionalField(name: String, arg: String)
}

fn convert_type_to_decoder(field: glance.Field(glance.Type)) -> FieldDecoder {
  let id = case field.label {
    Some(id) -> id
    _ -> panic as "unknown id"
  }

  io.debug("parsing field: " <> id)
  io.debug(field)

  case field.item {
    // List
    glance.NamedType(
      "List",
      module: _,
      parameters: [glance.NamedType("String", module: _, parameters: [])],
    ) -> Field(id, "dynamic.list(dynamic.string)")
    glance.NamedType(
      "List",
      module: _,
      parameters: [glance.NamedType("Int", module: _, parameters: [])],
    ) -> Field(id, "dynamic.list(dynamic.int)")
    glance.NamedType(
      "List",
      module: _,
      parameters: [glance.NamedType("Snowflake", module: _, parameters: [])],
    ) -> Field(id, "dynamic.list(dynamic.string)")
     glance.NamedType(
        "List",
        module: _,
        parameters: [glance.NamedType(name, module: _, parameters: [])],
      ) if name != "String" && name != "Int" && name != "Bool" ->
      Field(id, format("dynamic.list(decode_%)", [justin.snake_case(name)]))
    // Option
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("Float", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.float")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("Nil", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.string")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("Snowflake", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.string")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("String", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.string")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("Int", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.int")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [glance.NamedType("Bool", module: _, parameters: [])],
    ) -> OptionalField(id, "dynamic.bool")
    glance.NamedType(
        "Option",
        module: _,
        parameters: [glance.NamedType(name, module: _, parameters: [])],
      ) if name != "String" && name != "Int" && name != "Bool" ->
      OptionalField(id, format("decode_%", [justin.snake_case(name)]))
    // Option Dict
    glance.NamedType(
      "Option",
      module: _,
      parameters: [
        glance.NamedType(
          "Dict",
          module: _,
          parameters: [
            glance.NamedType("Snowflake", module: _, parameters: []),
            glance.NamedType(p2, module: _, parameters: []),
          ],
        ),
      ],
    ) ->
      OptionalField(
        id,
        format("dynamic.dict(dynamic.string, decode_%)", [justin.snake_case(p2)]),
      )
    // Option(List)
     glance.NamedType(
        "Option",
        module: _,
        parameters: [
          glance.NamedType(
            "List",
            module: _,
            parameters: [glance.NamedType("Snowflake", module: _, parameters: [])],
          ),
        ],
      ) ->
      OptionalField(
        id,
        "dynamic.list(dynamic.string)",
      )
    glance.NamedType(
        "Option",
        module: _,
        parameters: [
          glance.NamedType(
            "List",
            module: _,
            parameters: [glance.NamedType(name, module: _, parameters: [])],
          ),
        ],
      ) if name != "String" && name != "Int" && name != "Bool" ->
      OptionalField(
        id,
        format("dynamic.list(decode_%)", [justin.snake_case(name)]),
      )
    glance.NamedType(
      "Option",
      module: _,
      parameters: [
        glance.NamedType(
          "List",
          module: _,
          parameters: [glance.NamedType("Int", module: _, parameters: [])],
        ),
      ],
    ) -> OptionalField(id, "dynamic.list(dynamic.int)")
    glance.NamedType(
      "Option",
      module: _,
      parameters: [
        glance.NamedType(
          "List",
          module: _,
          parameters: [glance.NamedType("String", module: _, parameters: [])],
        ),
      ],
    ) -> OptionalField(id, "dynamic.list(dynamic.string)")
    // dynamic.Dynamic
    glance.NamedType("dynamic.Dynamic", module: _, parameters: []) ->
      Field(id, "dynamic.dynamic")
    // String
    glance.NamedType(name, module: _, parameters: []) if name == "Snowflake"
      || name == "String" -> Field(id, "dynamic.string")
    // Int
    glance.NamedType("Int", module: _, parameters: []) ->
      Field(id, "dynamic.int")
    glance.NamedType("Dynamic", module: _, parameters: []) ->
      Field(id, "dynamic.dynamic")
    glance.NamedType("Bool", module: _, parameters: []) ->
      Field(id, "dynamic.bool")
    glance.NamedType(name, module: _, parameters: []) ->
      Field(id, format("decode_%", [justin.snake_case(name)]))
    // Dict
    glance.NamedType(
      "Dict",
      module: _,
      parameters: [
        glance.NamedType(p1, module: _, parameters: []),
        glance.NamedType(p2, module: _, parameters: []),
      ],
    ) -> Field(id, format("dynamic.dict(dynamic.%, dynamic.%)", [
      justin.snake_case(p1), justin.snake_case(p2)
      ]))
    _ -> panic as "unsupported type"
  }
}

type Args {
  Args(
    types: List(String),
    out_file: String,
    import_module: String,
    rename: dict.Dict(String, String),
  )
}

fn parse_args(arguments: List(String)) -> Args {
  case arguments {
    ["--import-module", ..rest] -> {
      let assert #([val], rest) = list.split(rest, 1)
      let assert Args(..) as args = parse_args(rest)
      Args(..args, import_module: val)
    }
    ["--type", ..rest] -> {
      let assert #([val], rest) = list.split(rest, 1)
      let assert Args(..) as args = parse_args(rest)
      Args(
        ..args,
        types: args.types
        |> list.prepend(val),
      )
    }
    ["--out-file", ..rest] -> {
      let assert #([val], rest) = list.split(rest, 1)
      let assert Args(..) as args = parse_args(rest)
      Args(..args, out_file: val)
    }
    ["--rename", ..rest] -> {
      let assert #([v1, v2], rest) = list.split(rest, 2)
      let assert Args(..) as args = parse_args(rest)
      Args(
        ..args,
        rename: args.rename
        |> dict.insert(v1, v2),
      )
    }
    [] -> {
      Args(types: [], out_file: "", import_module: "", rename: dict.new())
    }
    _ -> panic as "parsing error"
  }
}

fn generate(type_name, fields: List(FieldDecoder)) {
  let fields =
    fields
    |> list.index_map(fn(x, idx) {
      let comma = case idx + 1 == list.length(fields) {
        True -> ""
        _ -> ","
      }

      let #(func_name, name, arg) = case x {
        Field(name, arg) -> #("dynamic.field", name, arg)
        OptionalField(name, arg) -> #("dynamic.optional_field", name, arg)
      }

      templ.object([
        #(
          "index",
          templ.string(
            "a"
            <> idx + 1
            |> int.to_string,
          ),
        ),
        #("func_name", templ.string(func_name)),
        #("key", templ.string(name)),
        #("value", templ.string(arg)),
        #("comma", templ.string(comma)),
      ])
    })

  do_template(decoder_template, [
    #("fields", templ.list(fields)),
    #("type_name", templ.string(type_name)),
    #("type_snake_case", templ.string(justin.snake_case(type_name))),
  ])
}

fn do_template(templ, args) -> String {
  let assert Ok(compiled) = templ.compile(templ)

  templ.render(compiled, args)
}

fn format(fmt: String, args: List(String)) -> String {
  case string.split_once(fmt, "%") {
    Ok(#(left, right)) -> {
      case args {
        [] -> ""
        [e1] -> left <> e1 <> right
        [e1, ..rest] -> left <> e1 <> format(right, rest)
      }
    }
    Error(_) -> ""
  }
}

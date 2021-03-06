defmodule Absinthe.Phoenix.Controller.Action do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @impl true
  @spec init(opts :: Keyword.t) :: Keyword.t
  def init(opts \\ []) do
    opts
  end

  @impl true
  @spec call(conn :: Plug.Conn.t, opts :: Keyword.t) :: Plug.Conn.t
  def call(conn, _opts) do
    controller = conn.private.phoenix_controller
    document_provider = Module.safe_concat(controller, GraphQL)
    case document_and_schema(conn, document_provider) do
      {doc, schema} when is_nil(doc) or is_nil(schema) ->
        conn
      {document, schema} ->
        execute(conn, schema, controller, document)
    end
  end

  @spec execute(conn :: Plug.Conn.t, schema :: Absinthe.Schema.t, controller :: module, document :: Absinthe.Blueprint.t) :: Plug.Conn.t
  defp execute(conn, schema, controller, document) do
    variables = parse_variables(document, conn.params, schema, controller)
    case Absinthe.Pipeline.run(document, pipeline(schema, controller, variables)) do
      {:ok, %{result: result}, _phases} ->
        conn
        |> Plug.Conn.put_private(:absinthe_variables, conn.params)
        |> Map.put(:params, result)
      {:error, msg, _phases} ->
        conn
        |> send_resp(500, msg)
    end
  end

  @spec document_key(conn :: Plug.Conn.t) :: nil | atom
  defp document_key(%{private: %{phoenix_action: name}}), do: to_string(name)
  defp document_key(_), do: nil

  @spec document_and_schema(conn :: Plug.Conn.t, document_provider :: Absinthe.Plug.DocumentProvider.Compiled.t) :: {nil | Absinthe.Blueprint.t, nil | Absinthe.Schema.t}
  defp document_and_schema(conn, document_provider) do
    case document_key(conn) do
      nil ->
        nil
      key ->
        {
          Absinthe.Plug.DocumentProvider.Compiled.get(document_provider, key, :compiled),
          document_provider.lookup_schema(key)
        }
    end
  end

  @spec pipeline(schema :: Absinthe.Schema.t, controller :: module, variables :: %{String.t => any}) :: Absinthe.Pipeline.t
  defp pipeline(schema, controller, variables) do
    controller.absinthe_pipeline(schema, variables)
  end

  @spec parse_variables(document :: Absinthe.Blueprint.t, params :: map, schema :: Absinthe.Schema.t, controller :: module) :: %{String.t => any}
  defp parse_variables(document, params, schema, controller) do
    params
    |> do_parse_variables(variable_types(document, schema), schema, controller)
  end

  @spec do_parse_variables(params :: map, variable_types :: %{String.t => Absinthe.Type.t}, schema :: Absinthe.Schema.t, controller :: module) :: map
  defp do_parse_variables(params, variable_types, schema, controller) do
    for {name, raw_value} <- params, into: %{} do
      target_type = Map.fetch!(variable_types, name)
      {
        name,
        controller.cast_param(raw_value, target_type, schema)
      }
    end
  end

  @type_mapping %{
    Absinthe.Blueprint.TypeReference.List => Absinthe.Type.List,
    Absinthe.Blueprint.TypeReference.NonNull => Absinthe.Type.NonNull
  }

  # TODO: Extract this from here & Absinthe.Phase.Schema to a common function
  @spec type_reference_to_type(Absinthe.Blueprint.TypeReference.t, Absinthe.Schema.t) :: Absinthe.Type.t
  defp type_reference_to_type(%Absinthe.Blueprint.TypeReference.Name{name: name}, schema) do
    Absinthe.Schema.lookup_type(schema, name)
  end
  for {blueprint_type, core_type} <- @type_mapping do
    defp type_reference_to_type(%unquote(blueprint_type){} = node, schema) do
      inner = type_reference_to_type(node.of_type, schema)
      %unquote(core_type){of_type: inner}
    end
  end

  # TODO: Extract this to a function (probably on Absinthe.Blueprint.Document.Operation)
  @spec variable_types(Absinthe.Blueprint.t, Absinthe.Schema.t) :: %{String.t => Absinthe.Type.t}
  defp variable_types(document, schema) do
    for %{name: name, type: type} <- Absinthe.Blueprint.current_operation(document).variable_definitions, into: %{} do
      {name, type_reference_to_type(type, schema)}
    end
  end

end

defmodule FlightDatastore.Modify do
  @moduledoc """
  Modify entity utils
  """

  @update_kind "_Flight_Update"
  @log_kind "_Flight_Log"

  alias FlightDatastore.Scope
  alias FlightDatastore.Find

  @doc """
  Check permission to modify data

  ## Examples

      iex> FlightDatastore.Modify.check([%{"kind" => "User", "action" => "insert"}], %{"_" => %{"User" => %{"insert" => %{}}}}, %{})
      true

      iex> FlightDatastore.Modify.check([%{"namespace" => "Demo", "kind" => "User", "action" => "insert"}], %{"Demo" => %{"User" => %{"insert" => %{}}}}, %{})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "User", "action" => "update"}], %{"_" => %{"User" => %{"insert" => %{}}}}, %{})
      false

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update"}], %{"_" => %{"User" => %{"insert" => %{}}}}, %{})
      false

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "properties" => %{"col" => "value"}}], %{"_" => %{"Profile" => %{"update" => %{"cols" => ["col"]}}}}, %{})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "properties" => %{"col" => "value"}}], %{"_" => %{"Profile" => %{"update" => %{"cols" => ["col","col2"]}}}}, %{})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "properties" => %{"unknown_col" => "value"}}], %{"_" => %{"Profile" => %{"update" => %{"cols" => ["col","col2"]}}}}, %{})
      false

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "key" => "some-id"}], %{"_" => %{"Profile" => %{"update" => %{"samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "key" => "other-id"}], %{"_" => %{"Profile" => %{"update" => %{"samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      false

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "key" => "some-id", "properties" => %{"col" => "value"}}], %{"_" => %{"Profile" => %{"update" => %{"cols" => ["col"], "samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "update", "key" => "other-id", "properties" => %{"col" => "value"}}], %{"_" => %{"Profile" => %{"update" => %{"cols" => ["col"], "samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      false

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "replace", "key" => "new-id", "old-key" => "some-id"}], %{"_" => %{"Profile" => %{"replace" => %{"samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      true

      iex> FlightDatastore.Modify.check([%{"kind" => "Profile", "action" => "replace", "key" => "new-id", "old-key" => "other-id"}], %{"_" => %{"Profile" => %{"replace" => %{"samekey" => "loginID"}}}}, %{"loginID" => "some-id"})
      false

      iex> FlightDatastore.Modify.check([], %{"_" => %{"User" => %{"insert" => %{}}}}, %{})
      false

      iex> FlightDatastore.Modify.check(nil, %{"_" => %{"User" => %{"insert" => %{}}}}, %{})
      false
  """
  def check(nil,_scopes,_credential), do: false
  def check([],_scopes,_credential), do: false
  def check(data,scopes,credential) do
    methods = [
      {"cols", fn info,cols ->
        info["properties"]
        |> Map.keys
        |> Enum.all?(fn col -> cols |> Enum.member?(col) end)
      end},
      {"samekey", fn info,name ->
        credential |> Map.has_key?(name) && (info["old-key"] || info["key"]) == credential[name]
      end},
    ]

    data
    |> Enum.all?(fn info ->
      action = info["action"]
      case Scope.get(scopes,info["namespace"],info["kind"]) do
        %{^action => scope} ->
          methods |> Enum.all?(fn {key,func} ->
            !scope[key] || func.(info,scope[key])
        end)
        _ -> false
      end
    end)
  end

  @doc """
  Execute modify
  """
  def execute(data) do
    data
    |> fill_properties
    |> to_request
    |> commit
  end

  def fill_properties(data) do
    data
    |> Enum.map(fn info ->
      unless info |> fill? do
        info
      else
        case Find.find_entity(info["namespace"], info["kind"], info["key"]) do
          nil -> info
          entity ->
            properties =
              entity
              |> Find.to_map(entity.properties |> Map.keys)
              |> Map.merge(info["properties"])
            %{ info | "properties" => properties }
        end
      end
    end)
  end
  defp fill?(info) do
    if info["action"] == "insert" || info["action"] == "delete" do
      false
    else
      ["key","properties"] |> Enum.all?(fn key -> info |> Map.has_key?(key) end)
    end
  end

  @doc """
  Convert operates to list of commit request

  ## Examples

      iex> FlightDatastore.Modify.to_request([%{"action" => "insert", "kind" => "User", "properties" => %{"name" => "user name", "email" => "user@example.com"}}, %{"action" => "update", "kind" => "Summary", "key" => 1, "properties" => %{"user_count" => 1}}, %{"action" => "delete", "kind" => "Guest", "key" => "guest"}])
      [{:insert,%Diplomat.Entity{key: %Diplomat.Key{id: nil, kind: "User", name: nil, namespace: nil, parent: nil, project_id: nil}, kind: "User", properties: %{"name" => %Diplomat.Value{value: "user name"}, "email" => %Diplomat.Value{value: "user@example.com"}}}}, {:update,%Diplomat.Entity{key: %Diplomat.Key{id: 1, kind: "Summary", name: nil, namespace: nil, parent: nil, project_id: nil}, kind: "Summary", properties: %{"user_count" => %Diplomat.Value{value: 1}}}}, {:delete,%Diplomat.Key{id: nil, kind: "Guest", name: "guest", namespace: nil, parent: nil, project_id: nil}}]

      iex> FlightDatastore.Modify.to_request([%{"action" => "replace", "kind" => "User", "key" => "user", "old-key" => "old-user", "properties" => %{"name" => "user name"}}])
      [{:update,%Diplomat.Entity{key: %Diplomat.Key{id: nil, kind: "User", name: "old-user", namespace: nil, parent: nil, project_id: nil}, kind: "User", properties: %{"name" => %Diplomat.Value{value: "user name"}}}}, {:delete,%Diplomat.Key{id: nil, kind: "User", name: "old-user", namespace: nil, parent: nil, project_id: nil}}, {:insert,%Diplomat.Entity{key: %Diplomat.Key{id: nil, kind: "User", name: "user", namespace: nil, parent: nil, project_id: nil}, kind: "User", properties: %{"name" => %Diplomat.Value{value: "user name"}}}}]
  """
  def to_request(data) do
    data
    |> Enum.flat_map(fn info ->
      case info["action"] do
        "delete" = action ->
          [{
            :"#{action}",
            Find.to_key(info["namespace"], info["kind"], info["key"]),
          }]
        "replace" ->
          [{
            :update,
            info["properties"] |> Find.to_entity(info["namespace"],info["kind"],info["old-key"]),
          },{
            :delete,
            Find.to_key(info["namespace"], info["kind"], info["old-key"]),
          },{
            :insert,
            info["properties"] |> Find.to_entity(info["namespace"],info["kind"],info["key"]),
          }]
        action ->
          [{
            :"#{action}",
            info["properties"] |> Find.to_entity(info["namespace"],info["kind"],info["key"]),
          }]
      end
    end)
  end

  def commit(request) do
    case Diplomat.Transaction.begin do
      {:error, _}=error -> error
      t ->
        request
        |> Diplomat.Entity.commit_request(:TRANSACTIONAL,t)
        |> Diplomat.Client.commit
    end
  end

  @doc """
  Get inserted keys from response

  ## Examples

      iex> FlightDatastore.Modify.inserted_keys(%Diplomat.Proto.CommitResponse{ index_updates: 6, mutation_results: [ %Diplomat.Proto.MutationResult{ key: %Diplomat.Proto.Key{ partition_id: %Diplomat.Proto.PartitionId{namespace_id: nil, project_id: "neon-circle-164919"}, path: [%Diplomat.Proto.Key.PathElement{id_type: {:id, 5730082031140864}, kind: "User"}] } }, %Diplomat.Proto.MutationResult{ key: %Diplomat.Proto.Key{ partition_id: %Diplomat.Proto.PartitionId{namespace_id: nil, project_id: "neon-circle-164919"}, path: [%Diplomat.Proto.Key.PathElement{id_type: {:id, 5167132077719552}, kind: "User"}] } } ] })
      [5730082031140864,5167132077719552]
  """
  def inserted_keys(response) do
    response.mutation_results |> Enum.flat_map(fn result ->
      case result.key do
        nil -> []
        key -> key.path |> Enum.flat_map(fn path ->
          case path.id_type do
            {:id, id} -> [id]
            _ -> []
          end
        end)
      end
    end)
  end

  @doc """
  Fill inserted keys to request data

  ## Examples

      iex> FlightDatastore.Modify.fill_keys([%{"action" => "insert"}],[1])
      [%{"action" => "insert", "key" => 1}]

      iex> FlightDatastore.Modify.fill_keys([%{"action" => "insert"}, %{"action" => "insert"}],[1,2])
      [%{"action" => "insert", "key" => 1}, %{"action" => "insert", "key" => 2}]

      iex> FlightDatastore.Modify.fill_keys([%{"action" => "insert", "key" => "key"}, %{"action" => "insert"}],[1])
      [%{"action" => "insert", "key" => "key"}, %{"action" => "insert", "key" => 1}]

      iex> FlightDatastore.Modify.fill_keys([%{"action" => "update"},%{"action" => "delete"},%{"action" => "insert"}],[1])
      [%{"action" => "update"},%{"action" => "delete"},%{"action" => "insert", "key" => 1}]

      iex> FlightDatastore.Modify.fill_keys([%{"action" => "update"}],[])
      [%{"action" => "update"}]
  """
  def fill_keys(data,keys) do
    keys |> Enum.reduce(data, fn key, acc -> key |> fill_key(acc) end)
  end
  defp fill_key(key,data) do
    finder = fn info ->
      info["action"] == "insert" && info["key"] == nil
    end
    case data |> Enum.find_index(finder) do
      nil -> data
      index ->
        {first, last} = data |> Enum.split(index)
        [target | tail] = last
        filled = target |> Map.put("key", key)
        first ++ [filled] ++ tail
    end
  end

  @doc """
  Logging updates
  """
  def log(data,scopes,credential) do
    data
    |> Enum.each(fn info ->
      scope = Scope.get(scopes,info["namespace"],info["kind"])
      if scope[info["action"]]["nolog"] do
        info |> log(credential)
      end
    end)
  end
  def log(info,credential) do
    update = %{
      "namespace" => info["namespace"],
      "kind" => info["kind"],
      "key" => info["key"],
      "at" => DateTime.utc_now |> DateTime.to_iso8601,
      "salt" => :rand.uniform(),
      "operator" => credential,
    }

    log = info
          |> Map.put("at", update["at"])
          |> Map.put("salt", update["salt"])
          |> Map.put("operator", update["operator"])

    case info["action"] do
      "insert" ->
        [
          {:insert, log |> to_log},
          {:insert, update |> to_update("first")},
          {:upsert, update |> to_update("last")},
        ] |> commit
      _ ->
        last = info |> find_last

        request = [
          {:insert, log |> Map.put("last", last |> to_log_key) |> to_log},
          {:upsert, update |> to_update("last")},
        ]

        case last |> find_log do
          nil -> request
          last_log -> [{:update, last_log |> Map.put("next", log |> to_log_key) |> to_log} | request]
        end |> commit
    end
  end

  defp find_last(data) do
    Find.find_entity(data["namespace"], @update_kind, data |> to_update_key("last"))
    |> Find.to_map(["kind","key","at","salt"])
  end
  defp find_log(data) do
    case data do
      nil -> nil
      update ->
        Find.find_entity(data["namespace"], @log_kind, update |> to_log_key)
        |> Find.to_map(["kind","key","at","salt","action","last","next","operator","properties"])
    end
  end

  defp to_log_key(data) do
    case data do
      nil -> nil
      info -> "#{info["kind"]}:#{info["key"]}:#{info["at"]}:#{info["salt"]}"
    end
  end
  defp to_log(data) do
    data
    |> Find.to_entity(data["namespace"],@log_kind,data |> to_log_key)
  end

  defp to_update(data,type) do
    data
    |> Map.put("type", type)
    |> Find.to_entity(data["namespace"],@update_kind,data |> to_update_key(type))
  end
  defp to_update_key(data,type) do
    "#{data["kind"]}:#{data["key"]}:#{type}"
  end
end

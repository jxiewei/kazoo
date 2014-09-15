-module(apk_parser).

%-include("../include/wh_log.hrl").

-record(tree, {root :: treenode()}).
-record(treenode, {type, key, value, childs}).

-export_type([tree/0, treenode/0]).

-export([build/1, find_node/2
        ,get_version_code/1
        ,get_version_name/1
        ,get_oem_name/1
        ,get_package_name/1]).

-type tree() :: #tree{}.
-type treenode() :: #treenode{}.

get_version_code(Tree) ->
    case find_node(Tree, [[{key, "manifest"}], [{key, "android:versionCode"}]]) of
        [Node|_] -> Node#treenode.value;
        [] -> 'undefined'
    end.

get_version_name(Tree) ->
    case find_node(Tree, [[{key, "manifest"}], [{key, "android:versionName"}]]) of
        [Node|_] -> Node#treenode.value;
        [] -> 'undefined'
    end.

get_oem_name(Parent) when is_record(Parent, treenode) -> 
    Found = lists:foldl(
                fun(E, Acc) ->
                    io:format("node value is ~p", [E#treenode.value]),
                    case E#treenode.value of
                        "oemName" -> 'true';
                        _ -> Acc
                    end
                end, 'false', Parent#treenode.childs),
    case Found of
        'true' -> 
            io:format("found oem node, parent is ~p~n", [Parent]),
            lists:foldl(
                fun(E, Acc) ->
                    case E#treenode.key of
                        "android:value" -> E#treenode.value;
                        _ -> Acc
                    end
                end, 'undefined', Parent#treenode.childs);
        _ -> 
            io:format("oem node not found~n"),
            'undefined'
    end;

get_oem_name(Tree) when is_record(Tree, tree) ->
    case find_node(Tree, [[{key, "manifest"}], [{key, "application"}], [{key, "meta-data"}]]) of
        [] -> 'error';
        Nodes -> lists:foldl(
                    fun(E, Acc) -> 
                        case Acc of
                            'undefined' -> get_oem_name(E);
                            _ -> Acc
                        end
                    end, 'undefined', Nodes)
    end.

get_package_name(Tree) ->
    case find_node(Tree, [[{key, "manifest"}], [{key, "package"}]]) of
        [Node|_] -> Node#treenode.value;
        [] -> 'error'
    end.


find_node(Tree, Keys=[_|_]) when is_record(Tree, tree) ->
    find_node([Tree#tree.root], Keys);
find_node(Nodes, [Key|OtherKeys]) ->
    case find_node_key(Nodes, Key) of
        N ->
            io:format("Key ~p found in nodes ~p~n", [Key, N]),
            case OtherKeys of
                [] -> N;
                _ -> 
                    find_node(lists:foldr(fun(E, Acc) -> E#treenode.childs ++ Acc end, [], N), OtherKeys)
            end
    end;
find_node(Nodes, []) -> Nodes.

match_node(Node, Conds = [_|_]) when is_list(Conds) -> 
    match_node(Node, Conds, 'true');
match_node(Node, Cond = {key, Val}) when is_tuple(Cond) ->
    case string:equal(Node#treenode.key, Val) of
        'true' -> 'true';
        _ -> 'false'
    end;
match_node(Node, Cond = {value, Val}) when is_tuple(Cond) ->
    case Node#treenode.value of
        Val -> 'true';
        _ -> 'false'
    end.

match_node(Node, [], Acc) -> Acc;
match_node(Node, [Cond|Others], Acc) ->
    case Acc of
        'false' -> 'false';
        'true' -> 
            match_node(Node, Others, match_node(Node, Cond))
    end.


find_node_key(Nodes, Key) ->
    find_node_key(Nodes, Key, []).

find_node_key([], _Key, Acc) -> Acc;
find_node_key([Node|Others], Key, Acc) ->
    #treenode{key=Name} = Node,
    Acc1 = case match_node(Node, Key) of
        'true' -> 
            io:format("Node matched key ~p~n", [Key]),
            [Node|Acc];
        _ -> Acc
    end,
    find_node_key(Others, Key, Acc1).


build(File) ->
    io:format("jerry -- building tree for file ~p", [File]),
    Output = os:cmd("aapt l -a " ++ File),
    Lines = string:tokens(Output, "\n"),
    {'ok', RootNode, []} = parse(Lines),
    #tree{root=RootNode}.

extractRaw(Line) ->
    string:substr(Line, 2, string:str(Line, " (Raw:")-3).

parse_value(Rest) ->
    case Rest of
        [$"|_] -> extractRaw(Rest);
        _ -> maybe_parse_boolean_value(Rest)
    end.

maybe_parse_boolean_value(Rest) ->
    case string:substr(Rest, 1, 11) of
        "(type 0x12)" -> string:substr(Rest, 14, 1) =:= "1";
        _ -> maybe_parse_integer_value(Rest)
    end.

maybe_parse_integer_value(Part1) ->
    case string:substr(Part1, 1, 11) of
        "(type 0x10)" -> list_to_integer(string:substr(Part1, 14), 16);
        %Parse failed, return hex value
        _ -> Part1
    end.

normalize_name(Name) ->
    case string:chr(Name, $() of
        Index when Index > 0 ->
            string:strip(string:substr(Name, 1, Index-1));
        _ -> string:strip(Name)
    end.

%% parse a single line
maybe_parseline(Line) ->
    maybe_parse_e_line(Line).

maybe_parse_e_line(Line) ->
    case re:run(Line, "^( +)(E): (.+ )(.*)$", [{capture, all_but_first, list}]) of
        {'match', [Indent, Type, Name, Rest]} ->
            RealName = normalize_name(Name),
            Depth = length(Indent) div 2,
            {'ok', #treenode{type=Type, key=RealName, value='undefined', childs=[]}, Depth};
        'nomatch' -> maybe_parse_a_line(Line)
    end.

    
maybe_parse_a_line(Line) ->
    case re:run(Line, "^( +)(A): (.*)=(.*)$", [{capture, all_but_first, list}]) of
        {'match', [Indent, Type, Name, Rest]} ->
            RealName = normalize_name(Name),
            Depth = length(Indent) div 2,
            {'ok', #treenode{type=Type, key=RealName, value=parse_value(Rest), childs=[]}, Depth};
        'nomatch' -> 'error'
    end.

parse([]) -> {'ok', 'undefined'};
parse([Line|Others]) ->
    case string:strip(Line) of
        "Android manifest:" -> parse_manifest(Others);
        _ -> parse(Others)
    end.

parse_manifest([Line|Others]) ->
    case maybe_parseline(Line) of
        {'ok', RootNode, Depth} -> parse(Others, RootNode, Depth);
        %continue parsing
        'error' -> parse_manifest(Others)
    end.


parse([], ParentNode, _Depth) -> {'ok', ParentNode, []};
parse([Line|Others] = Lines, ParentNode, Depth) ->
    #treenode{childs=Childs} = ParentNode,
    case maybe_parseline(Line) of
        {'ok', Node, Depth1} ->
            case Depth1 =< Depth of
                'true' -> 
                    {'ok', ParentNode, Lines};
                _ ->
                    {'ok', N, Remains} = parse(Others, Node, Depth1),
                    %child tree parsed over, continue at current depth
                    parse(Remains, ParentNode#treenode{childs=[N|Childs]}, Depth)
            end;
        'error' -> 
            parse(Others, ParentNode, Depth)
    end.


-module(port_wrapper).
-export([wrap/1, wrap/2, wrap_link/1, wrap_link/2, send/2, shutdown/1, close/1, rpc/2]).

wrap(Command) ->
 spawn(fun() -> process_flag(trap_exit, true), Port = create_port(Command), loop(Port, infinity, Command) end).
wrap(Command, Timeout) ->
  spawn(fun() -> process_flag(trap_exit, true), Port = create_port(Command), loop(Port, Timeout, Command) end).

wrap_link(Command) ->
 spawn_link(fun() -> process_flag(trap_exit, true), Port = create_port(Command), link(Port), loop(Port, infinity, Command) end).
wrap_link(Command, Timeout) ->
  spawn_link(fun() -> process_flag(trap_exit, true), Port = create_port(Command), link(Port), loop(Port, Timeout, Command) end).

rpc(WrappedPort, Message) ->
  send(WrappedPort, Message),
  receive
    {WrappedPort, Result} -> {ok, Result}
  after 15000 ->
    {error, timed_out, WrappedPort}
  end.

send(WrappedPort, Message) ->
  WrappedPort ! {self(), {command, Message}},
  WrappedPort.

shutdown(WrappedPort) ->
  WrappedPort ! shutdown,
  true.

close(WrappedPort) ->
  WrappedPort ! noose,
  true.

create_port(Command) ->
  open_port({spawn, Command}, [{packet, 4}, nouse_stdio, exit_status, binary]).


stream_response(Port, Source, Timeout) ->
    receive
        {Port, {data, <<>>}} -> % final byte stream
            % error_logger:info_msg("Port Wrapper ~p send last null in byte stream!~n", [self()]),
            Source ! {data, <<>>},
            Source ! final;
        {Port, {data, Result}} ->
            % error_logger:info_msg("Port Wrapper ~p byte stream ~p~n", [self(), Result]),
            Source ! {data, Result},
            stream_response(Port, Source, Timeout)
        after Timeout ->
                timeout
        end.

send_reply(Port, Source, Timeout) ->
    receive
        {Port, {data, Result}} ->
            case binary_to_term(Result) of
                {info, stream, _Options} ->
                    Source ! {self(), stream}, % will get response
                    Source ! {data, Result},
                    %error_logger:info_msg("Port Wrapper ~p got stream~n", [self()]),
                    stream_response(Port, Source, Timeout);
                _Any ->
                    %error_logger:info_msg("Port Wrapper ~p forward to source ~p~n", [self(), binary_to_term(Result)]),
                    Source ! {self(), Result}
            end
    after Timeout ->
            timeout
    end.

loop(Port, Timeout, Command) ->
  receive
    noose ->
      port_close(Port),
      noose;
    shutdown ->
      port_close(Port),
      exit(shutdown);
    {Source, {command, Message}} ->
      Port ! {self(), {command, Message}},
          case send_reply(Port, Source, Timeout) of
              timeout ->
                  error_logger:error_msg("Port Wrapper ~p timed out in mid operation (~p)!~n", [self(), Message]),
                                                % We timed out, which means we need to close and then restart the port
                  port_close(Port), % Should SIGPIPE the child.
                  exit(timed_out);
              _ ->
                  Source ! {self(), ok},
                  loop(Port,Timeout,Command)
              end;
    {Port, {exit_status, _Code}} ->
      % Hard and Unanticipated Crash
      error_logger:error_msg( "Port closed! ~p~n", [Port] ),
      exit({error, _Code});
    {'EXIT',_Pid,shutdown} ->
      port_close(Port),
      exit(shutdown);
    Any ->
      error_logger:warning_msg("PortWrapper ~p got unexpected message: ~p~n", [self(), Any]),
      loop(Port, Timeout, Command)
  end.

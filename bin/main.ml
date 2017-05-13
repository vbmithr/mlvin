open Core.Std
open Mlvin
open Cmdliner

let token =
  let doc = "The Slack API access token" in
  Cmdliner.Arg.(required & opt (some string) None & info ["t"; "token"] ~docv:"TOKEN" ~doc)

let info =
  let doc = "My own Slack Bot." in
  Cmdliner.Term.info "mlvin" ~doc

let rec restart_listener restart_r f =
  let open Async.Std in
  Pipe.read restart_r >>= (fun m ->
    match m with
    | `Ok "restart" ->
        printf "Restarting listener\n";
        f ();
        restart_listener restart_r f
    | _ ->
        printf "Got other message\n";
        restart_listener restart_r f)

let rec feedback_loop feedback_r restart_w =
  let open Async.Std in
  Pipe.read feedback_r >>= (fun r ->
    match r with
    | `Ok Data.KillMeNow f ->
        f ();
        Pipe.write restart_w "restart" >>= (fun _ ->
          feedback_loop feedback_r restart_w)
    | `Ok Data.Simple x ->
        printf "Got a simple msg: %s\n" x;
        feedback_loop feedback_r restart_w
    | `Eof ->
        Deferred.return (printf "Eof; closing the feedback loop\n"))

let run token =
  let open Async.Std in
  let (restart_r, restart_w) = Pipe.create () in
  let (feedback_r, feedback_w) = Pipe.create () in
  let f () =
    let module Json = Yojson.Basic.Util in
    let module Handler = Async.Std.Handler in
    let handler = Handler.create (fun x -> printf "Url: %s\n" x) in
    let rtm = Slack.start_rtm token in
    let url_json = rtm >>| fun r -> Json.member "url" r in
    let url = url_json >>| fun r -> Json.to_string r in
    let _ = Handler.install handler url in
    url >>| (fun url -> Slack.client (Uri.of_string url) feedback_w)
  in
  let _ = feedback_loop feedback_r restart_w in
  let _ = restart_listener restart_r f in
  let _ = Pipe.write restart_w "restart" in
  never_returns (Scheduler.go ~raise_unhandled_exn:true ())

let execute = Cmdliner.Term.(
  pure run $ token)

let () =
  match Cmdliner.Term.eval (execute, info) with
  | `Error _ -> exit 1
  | _ -> exit 0

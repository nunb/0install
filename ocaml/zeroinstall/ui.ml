(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

open Support.Common

class type ui_handler =
  object
    (** A new download has been added (may still be queued).
     * @param cancel function to call to cancel the download
     * @param url the URL being downloaded
     * @param hint the feed associated with this download
     * @param size the expected size in bytes, if known
     * @param tmpfile the temporary file where we are storing the contents (for progress reporting) *)
    method start_monitoring : cancel:(unit -> unit) -> url:string -> hint:string -> size:(Int64.t option) -> tmpfile:filepath -> unit Lwt.t

    (** A download has finished (successful or not) *)
    method stop_monitoring : filepath -> unit Lwt.t

    (** More information about a key has arrived *)
    method update_key_info : Support.Gpg.fingerprint -> Support.Qdom.element -> unit Lwt.t

    (** Ask the user to confirm they trust at least one of the signatures on this feed.
     * Return the list of fingerprints the user wants to trust. *)
    method confirm_keys : General.feed_url -> Support.Qdom.element -> Support.Gpg.fingerprint list Lwt.t

    (** Ask the user to confirm they are happy to install these distribution packages. *)
    method confirm_distro_install : Yojson.Basic.json list -> [`ok | `aborted_by_user] Lwt.t
  end

class python_ui (slave:Python.slave) =
  let downloads = Hashtbl.create 10 in

  let () =
    Python.register_handler "abort-download" (function
      | [`String tmpfile] ->
          begin try
            Hashtbl.find downloads tmpfile ()
          with Not_found -> log_info "abort-download: %s not found" tmpfile end;
          Lwt.return `Null
      | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
    ) in

  object (_ : #ui_handler)
    method start_monitoring ~cancel ~url ~hint ~size ~tmpfile =
      Hashtbl.add downloads tmpfile cancel;
      let size =
        match size with
        | None -> `Null
        | Some size -> `Float (Int64.to_float size) in
      let details = `Assoc [
        ("url", `String url);
        ("hint", `String hint);
        ("size", size);
        ("tempfile", `String tmpfile);
      ] in
      slave#invoke_async (`List [`String "start-monitoring"; details]) Python.expect_null

    method stop_monitoring tmpfile =
      slave#invoke_async (`List [`String "stop-monitoring"; `String tmpfile]) Python.expect_null

    method update_key_info fingerprint xml =
      slave#invoke_async ~xml (`List [`String "update-key-info"; `String fingerprint]) Python.expect_null

    method confirm_keys feed_url xml =
      let request = `List [`String "confirm-keys"; `String feed_url] in
      slave#invoke_async ~xml request (function
        | `List confirmed_keys -> confirmed_keys |> List.map Yojson.Basic.Util.to_string
        | _ -> raise_safe "Invalid response"
      )

    method confirm_distro_install package_impls =
      let request = `List [`String "confirm-distro-install"; `List package_impls] in
      slave#invoke_async request (function
        | `String "ok" -> `ok
        | `String "aborted-by-user" -> `aborted_by_user
        | _ -> raise_safe "Invalid response"
      )
  end

class console_ui slave =
  object
    inherit python_ui slave
  end

class batch_ui slave =
  object (_ : #ui_handler)
    inherit python_ui slave

    method! start_monitoring ~cancel:_ ~url:_ ~hint:_ ~size:_ ~tmpfile:_ = Lwt.return_unit
    method! stop_monitoring _tmpfile = Lwt.return_unit

(* For now, for the unit-tests, fall back to Python.

    method confirm_keys _feed_url _xml =
      raise_safe "Can't confirm keys as in batch mode."

    method update_key_info _fingerprint _xml = assert false

    method confirm_distro_install _package_impls =
      raise_safe "Can't confirm installation of distribution packages as in batch mode."
*)
  end

let make_ui (system:system) (slave:Python.slave) use_gui : ui_handler =
  match use_gui with
  | No ->
      if system#isatty Unix.stderr then
        new console_ui slave
      else
        new batch_ui slave
  | Yes | Maybe -> new python_ui slave

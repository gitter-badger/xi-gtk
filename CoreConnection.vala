// Copyright 2016 Elias Aebi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

namespace Xi {

class CoreConnection {
	private Pid pid;
	private UnixOutputStream core_stdin;
	private DataInputStream core_stdout;
	private DataInputStream core_stderr;
	private int id;
	public class ResponseHandler {
		public delegate void Delegate(Json.Node result);
		private Delegate d;
		public ResponseHandler(owned Delegate d) {
			this.d = (owned)d;
		}
		public void invoke(Json.Node result) {
			d(result);
		}
	}
	private HashTable<int, ResponseHandler> response_handlers;

	public signal void update_received(string tab, int64 first_line, int64 height, Json.Array lines, int64 scrollto_line, int64 scrollto_column);

	private void handle_update(Json.Object params) {
		var tab = params.get_string_member("tab");
		var update = params.get_object_member("update");
		var first_line = update.get_int_member("first_line");
		var height = update.get_int_member("height");
		var lines = update.get_array_member("lines");
		var scrollto = update.get_array_member("scrollto");
		update_received(tab, first_line, height, lines, scrollto.get_int_element(0), scrollto.get_int_element(1));
	}

	private bool receive() {
		try {
			string line = core_stdout.read_line_utf8(null);
			//stdout.printf("core to front-end: %s\n", line);
			var parser = new Json.Parser();
			parser.load_from_data(line);
			var root = parser.get_root().get_object();
			if (root.has_member("id")) {
				// response
				int id = (int)root.get_int_member("id");
				var handler = response_handlers[id];
				if (handler != null) {
					var result = root.get_member("result");
					handler.invoke(result);
					response_handlers.remove(id);
				}
			} else {
				var method = root.get_string_member("method");
				var params = root.get_member("params");
				switch (method) {
					case "update":
						handle_update(params.get_object());
						break;
				}
			}
		} catch (Error error) {
			stderr.printf("error: %s\n", error.message);
		}
		return true;
	}

	private void send_message(string method, Json.Object params = new Json.Object()) {
		var root = new Json.Object();
		root.set_int_member("id", id++);
		root.set_string_member("method", method);
		root.set_object_member("params", params);
		var root_node = new Json.Node(Json.NodeType.OBJECT);
		root_node.set_object(root);
		var generator = new Json.Generator();
		generator.set_root(root_node);
		try {
			generator.to_stream(core_stdin);
			core_stdin.write("\n".data);
			core_stdin.flush();
			//stdout.printf("front-end to core: %s\n", generator.to_data(null));
		} catch (Error error) {
			stderr.printf("error: %s\n", error.message);
		}
	}

	public void send_new_tab(owned ResponseHandler.Delegate response_handler) {
		response_handlers[id] = new ResponseHandler((owned)response_handler);
		send_message("new_tab");
	}

	public void send_edit(string tab, string method, Json.Object edit_params = new Json.Object()) {
		var params = new Json.Object();
		params.set_string_member("method", method);
		params.set_string_member("tab", tab);
		params.set_object_member("params", edit_params);
		send_message("edit", params);
	}

	public void send_insert(string tab, string chars) {
		var params = new Json.Object();
		params.set_string_member("chars", chars);
		send_edit(tab, "insert", params);
	}

	public void send_open(string tab, string filename) {
		var params = new Json.Object();
		params.set_string_member("filename", filename);
		send_edit(tab, "open", params);
	}

	public void send_click(string tab, int64 line, int64 column, int64 modifiers, int64 click_count) {
		var edit_params = new Json.Array();
		edit_params.add_int_element(line);
		edit_params.add_int_element(column);
		edit_params.add_int_element(modifiers);
		edit_params.add_int_element(click_count);
		var params = new Json.Object();
		params.set_string_member("method", "click");
		params.set_string_member("tab", tab);
		params.set_array_member("params", edit_params);
		send_message("edit", params);
	}

	public void send_drag(string tab, int64 line, int64 column, int64 modifiers) {
		var edit_params = new Json.Array();
		edit_params.add_int_element(line);
		edit_params.add_int_element(column);
		edit_params.add_int_element(modifiers);
		var params = new Json.Object();
		params.set_string_member("method", "drag");
		params.set_string_member("tab", tab);
		params.set_array_member("params", edit_params);
		send_message("edit", params);
	}

	public void send_render_lines(string tab, int64 first_line, int64 last_line, owned ResponseHandler.Delegate response_handler) {
		var params = new Json.Object();
		params.set_int_member("first_line", first_line);
		params.set_int_member("last_line", last_line);
		response_handlers[id] = new ResponseHandler((owned)response_handler);
		send_edit(tab, "render_lines", params);
	}

	private static DataInputStream create_input_stream(int fd, owned PollableSourceFunc func) {
		var stream = new UnixInputStream(fd, true);
		var source = stream.create_source();
		source.set_callback((owned)func);
		source.attach(null);
		return new DataInputStream(stream);
	}

	public CoreConnection(string[] command) {
		response_handlers = new HashTable<int, ResponseHandler>(direct_hash, direct_equal);
		try {
			int stdin_fd, stdout_fd, stderr_fd;
			Process.spawn_async_with_pipes(null, command, null, SpawnFlags.SEARCH_PATH, null, out pid, out stdin_fd, out stdout_fd, out stderr_fd);
			core_stdin = new UnixOutputStream(stdin_fd, true);
			core_stdout = create_input_stream(stdout_fd, receive);
			core_stderr = create_input_stream(stderr_fd, () => {
				//string line = core_stderr.read_line();
				//stdout.printf("xi-core stderr: %s\n", line);
				return false;
			});
		} catch (SpawnError error) {
			stderr.printf("spawn error: %s\n", error.message);
		}
	}
}

}

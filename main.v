module main

import os
import flag

fn get_gopath() string {
	mut gopath := os.getenv('GOPATH')
	if gopath == '' {
		gopath = os.getenv('HOME') + '/go'
	}
	gopath = gopath.replace('\\', '/')
	println('GOPATH: ${gopath}')
	return gopath
}

fn parse_go_mod(go_mod string) []string {
	mut packages := []string{}
	lines := go_mod.split('\n')
	mut in_require_block := false
	for line in lines {
		trimmed_line := line.trim_space()
		if trimmed_line.starts_with('require (') {
			in_require_block = true
			continue
		}
		if in_require_block && trimmed_line == ')' {
			in_require_block = false
			continue
		}
		if in_require_block || trimmed_line.starts_with('require ') {
			package_name := trimmed_line.replace('require ', '').replace(' // indirect',
				'').split(' ')[0..2].join('@')
			packages << package_name
		}
	}
	return packages
}

fn copy_sources(package_dir string, root_package_dir string) {
	if !os.exists('${package_dir}/go.mod') {
		println('No go.mod found in ${package_dir}')
		return
	}
	go_mod := os.read_file('${package_dir}/go.mod') or { panic(err) }
	packages := parse_go_mod(go_mod)
	gopath := get_gopath()
	for package in packages {
		println('Copying ${package} ...')
		source_path := '${gopath}/pkg/mod/${package}'
		if !os.exists(source_path) {
			println('Package ${package} not found in ${gopath}/pkg/mod')
			continue
		}
		destination_path := '${root_package_dir}/package_sources/${package}'
		if os.exists(destination_path) {
			continue
		}
		os.mkdir_all(destination_path) or { panic(err) }
		os.cp_all(source_path, destination_path, false) or {
			panic('Failed to copy ${source_path} to ${package_dir}; code: ${err.code()}, message: ${err.msg()}')
		}
		copy_sources(destination_path, root_package_dir)
	}
}

fn transpile_sources(go_package_dir string, v_package_dir string) {
	package_sources_dir := '${go_package_dir}/package_sources'
	if !os.exists(package_sources_dir) {
		println('No package sources found in ${package_sources_dir}')
		return
	}

	file_callback := fn [v_package_dir, package_sources_dir] (file string) {
		mut file_path := file
		file_path = file_path.replace('\\', '/').replace('${package_sources_dir}', '${v_package_dir}')
		last_slash_index := file_path.last_index('/') or { -1 }
		if last_slash_index != -1 {
			file_path = file_path[0..last_slash_index]
		}
		os.mkdir_all(file_path) or { panic(err) }
		if file.ends_with('.go') {
			res := os.system('v run go2v ${file}')
			if res != 0 {
				println('Failed to transpile ${file}')
			}
			destination :=
				'${file}'.replace('\\', '/').replace('${package_sources_dir}', '${v_package_dir}').substr_ni(0, -3) +
				'.v'
			os.mv('${file}'.substr_ni(0, -3) + '.v', destination) or { panic(err) }
		} else if os.is_file(file) {
			os.symlink('${file}', '${file}'.replace('\\', '/').replace('${package_sources_dir}',
				'${v_package_dir}')) or { panic(err) }
		}
	}

	os.walk(package_sources_dir, file_callback)
}

fn install_package(package_name string) {
	println('Installing ${package_name}')
	get_package(package_name)
}

fn get_package(package_name string) {
	println('Getting ${package_name}')
	go_package_dir := '.go-packages'
	if !os.exists(go_package_dir) {
		os.mkdir(go_package_dir) or { panic(err) }
		os.mkdir('${go_package_dir}/package_sources') or { panic(err) }
	}

	if !os.exists('${go_package_dir}/go.mod') {
		os.system('cd ${go_package_dir} && go mod init v-go')
	}

	os.system('cd ${go_package_dir} && go get ${package_name}')

	copy_sources(go_package_dir, go_package_dir)

	v_package_dir := '.v-go-packages'
	transpile_sources(go_package_dir, v_package_dir)

	println('Package ${package_name} downloaded to ${go_package_dir}')
}

fn remove_package(package_name string) {
	println('Removing ${package_name}')
	package_dir := '.go-packages'
	if !os.exists(package_dir) {
		println('Package directory does not exist')
		return
	}

	os.system('cd ${package_dir} && go mod edit -droprequire=${package_name}')
	os.system('cd ${package_dir} && go mod tidy')

	package_sources_dir := '${package_dir}/package_sources'
	if os.exists(package_sources_dir) {
		os.rmdir_all(package_sources_dir) or { panic(err) }
		os.mkdir(package_sources_dir) or { panic(err) }
	}

	copy_sources(package_dir, package_dir)

	println('Package ${package_name} removed and sources updated')
}

fn main() {
	mut fp := flag.new_flag_parser(os.args)
	fp.application('v-go')
	fp.version('0.0.1')
	fp.description('v-go is an utility that lets you install Go packages and and use them in V')
	fp.usage_example('install fyne.io/fyne/v2@latest')
	fp.usage_example('get fyne.io/fyne/v2')
	fp.usage_example('remove fyne.io/fyne/v2')
	fp.limit_free_args_to_exactly(2)!
	fp.skip_executable()

	args := fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		exit(1)
	}

	command := args[0]
	package_name := args[1]

	match command {
		'install' {
			install_package(package_name)
		}
		'get' {
			get_package(package_name)
		}
		'remove' {
			remove_package(package_name)
		}
		else {
			eprintln('Unknown command: ${command}')
			println(fp.usage())
			exit(1)
		}
	}
}

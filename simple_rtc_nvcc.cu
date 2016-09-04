#include "array.h"

#include <cstdlib>      // EXIT_FAILURE, etc
#include <string>
#include <iostream>
#include <fstream>
#include <dlfcn.h>      // dynamic library loading, dlopen() etc
#include <cxxabi.h>
#include <sys/stat.h>
#include <unordered_map>
#include <tuple>

template<typename Cls>
std::string get_class_name() {
    int status;
    char * demangled = abi::__cxa_demangle(
        typeid(Cls).name(),
        0,
        0,
        &status
    );
    return std::string(demangled);
}

template<typename... Args, typename std::enable_if<sizeof... (Args) == 0, int>::type = 0>
void get_function_arguments(int i, std::string* call_ptr) {}

template<typename Arg, typename... Args>
void get_function_arguments(int i, std::string* call_ptr) {
    std::string& call = *call_ptr;
    if (i > 0) {
        call = call + ", ";
    }
    call = call + get_class_name<Arg>() + " " + (char)(((int)'a') + i);
    get_function_arguments<Args...>(i+1, call_ptr);
}

template<typename... Args>
std::string get_function_arguments() {
    std::string s;
    get_function_arguments<Args...>(0, &s);
    return s;
}

struct ModulePointer {
    void* module_;
    std::string libname_;

    ModulePointer(const std::string& libname) : module_(NULL), libname_(libname) {
        module_ = dlopen(libname_.c_str(), RTLD_LAZY);
        if(!module_) {
            std::cerr << "error loading library:\n" << dlerror() << std::endl;
            exit(EXIT_FAILURE);
        }
    }

    ~ModulePointer() {
        if (module_) {
            dlclose(module_);
        }
    }
};

struct Module {
    std::shared_ptr<ModulePointer> module_ptr_;

    Module() : module_ptr_(NULL) {}
    Module(const std::string& libname) :
            module_ptr_(std::make_shared<ModulePointer>(libname)) {
    }

    void* module() {
        return module_ptr_->module_;
    }

    template<typename T>
    T get_symbol(const std::string& name) {
        void* symbol = dlsym(module(), name.c_str());
        const char* dlsym_error = dlerror();
        if (dlsym_error != NULL) {
            std::cerr << "error loading symbol:\n" << dlsym_error << std::endl;
            exit(EXIT_FAILURE);
        }
        return reinterpret_cast<T>(symbol);
    }

};

namespace std {
    template<typename... TTypes>
    class hash<std::tuple<TTypes...>> {
        private:
            typedef std::tuple<TTypes...> Tuple;

            template<int N>
            size_t operator()(Tuple value) const {
                return 0;
            }

            template<int N, typename THead, typename... TTail>
            size_t operator()(Tuple value) const {
                constexpr int Index = N - sizeof...(TTail) - 1;
                return hash<THead>()(std::get<Index>(value)) ^ operator()<N, TTail...>(value);
            }

        public:
            size_t operator()(Tuple value) const {
                return operator()<sizeof...(TTypes), TTypes...>(value);
            }
    };
}

bool file_exists (const std::string& fname) {
    struct stat buffer;
    return (stat (fname.c_str(), &buffer) == 0);
}

struct Compiler {
    std::unordered_map<std::tuple<std::size_t, std::size_t>, Module> modules;

    // compile code, instantiate class and return pointer to base class
    // https://www.linuxjournal.com/article/3687
    // http://www.tldp.org/HOWTO/C++-dlopen/thesolution.html
    // https://stackoverflow.com/questions/11016078/
    // https://stackoverflow.com/questions/10564670/
    template<typename... Args>
    std::function<void(Args...)> compile(
            const std::string& code,
            std::string funcname,
            bool force_recompilation) {

        std::size_t code_hash = std::hash<std::string>()(code);
        std::string func_args = get_function_arguments<Args...>();
        std::size_t arg_hash  = std::hash<std::string>()(func_args);
        std::tuple<std::size_t, std::size_t> module_key(code_hash, arg_hash);

        bool module_never_loaded = modules.find(module_key) == modules.end();

        if (force_recompilation || module_never_loaded) {
            // temporary cpp/library output files
            std::string outpath = "/tmp";
            std::string base_name = make_message(outpath, "/", code_hash, arg_hash);
            std::string libfile = base_name + ".so";

            bool module_never_compiled = !file_exists(libfile);

            if (force_recompilation || module_never_compiled) {
                std::cout << "compiling..." << std::endl;
                std::string headerfile = "array.h";
                std::string cppfile = base_name + ".cu";
                std::string logfile = base_name + ".log";

                std::ofstream out(cppfile.c_str(), std::ofstream::out);
                if (out.bad()) {
                    std::cout << "cannot open " << cppfile << std::endl;
                    exit(EXIT_FAILURE);
                }
                // copy required header file to outpath
                std::string cp_cmd="cp " + headerfile + " " + outpath;
                system(cp_cmd.c_str());

                std::string call_args;
                for (int i = 0; i < sizeof...(Args); i++) {
                    if (i > 0) {
                        call_args = call_args + ", ";
                    }
                    call_args = call_args + (char)(((int)'a') + i);
                }
                // add necessary header to the code
                std::string newcode = "#include \"" + headerfile + "\"\n\n"
                                      + code + "\n\n"
                                      // here we put extern c to void name mangling:
                                      "extern \"C\" void maker (" +
                                      get_function_arguments<Args...>() +
                                      ") {\n"
                                      + funcname + "(" + call_args + ");\n"
                                      "}\n";
                // output code to file
                out << newcode;
                out.flush();
                out.close();
                // compile the code
                std::string cmd = "nvcc -std=c++11 " + cppfile + " -o " + libfile
                                  + " -O2 -shared &> " + logfile;
                int ret = system(cmd.c_str());
                if (WEXITSTATUS(ret) != EXIT_SUCCESS) {
                    std::cout << "compilation failed, see " << logfile << std::endl;
                    exit(EXIT_FAILURE);
                }
            } else {
                std::cout << "module previously compiled. Reusing" << std::endl;
            }
            Module module(libfile);
            modules[module_key] = module;
        } else {
            std::cout << "module previously loaded. Reusing" << std::endl;
        }
        std::function<void(Args...)> method = modules[module_key].get_symbol<void(*)(Args...)>("maker");
        return method;
    }
};

std::function<void(ArrayGather<float>, Array<float>)> get_func_with_operator(
        Compiler& compiler,
        std::string operator_name) {
    std::string code = (
        "struct CustomSaver {\n"
        "    template<typename T>\n"
        "    static void XINLINE save(T& left, const T& right) {\n"
        "        left " + operator_name + "= right;\n"
        "    }\n"
        "};\n"
        "\n"
        "template<typename SrcT>\n"
        "void rtc_func(ArrayGather<SrcT> source,\n"
        "              const Array<SrcT>& updates,\n"
        "              cudaStream_t stream = NULL) {\n"
        "    scatter_saver<CustomSaver>(\n"
        "        source.array_, source.indices_, updates, stream\n"
        "    );\n"
        "};"
    );
    return compiler.compile<ArrayGather<float>, Array<float>>(code, "rtc_func", false);
}

int main(int argc, char** argv) {
    int dim = 5;
    int cols = 3;

    Array<float> source({dim, cols}, DEVICE_T_GPU);
    source = 0;

    Array<float> updates({dim, cols}, DEVICE_T_GPU);
    updates = 2;

    Array<int> indices({dim}, DEVICE_T_CPU);
    int i = 0;
    for (auto index : {0, 0, 2, 1, 2}) {
        indices[i++] = index;
    }
    indices.print();
    auto indices_gpu = indices.to_device(DEVICE_T_GPU);
    source.print();
    // increment repeatedly at this location:
    source[indices_gpu] += updates;
    source.print();
    // decrement repeatedly at this location:
    source[indices_gpu] -= updates;
    source.print();
    // not well defined in many to one setup
    source[indices_gpu] = updates;
    source.print();

    // RTC
    std::string operator_name = "+";
    // choose symbol at runtime
    if (argc > 1) {
        operator_name = argv[1];
    }

    Compiler compiler;

    // run functor defined by user at runtime:
    auto func = get_func_with_operator(compiler, operator_name);
    func(source[indices_gpu], updates);
    source.print();

    // decrement repeatedly at this location:
    auto func2 = get_func_with_operator(compiler, "-");
    func2(source[indices_gpu], updates);
    source.print();

    // run functor defined by user at again:
    func(source[indices_gpu], updates);
    source.print();

    return EXIT_SUCCESS;
}

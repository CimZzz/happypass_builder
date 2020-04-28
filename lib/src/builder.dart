import 'dart:async';
import 'dart:math';
import 'dart:mirrors';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:build/build.dart';

import 'annotations.dart';

PostProcessBuilder cleanBuilder(BuilderOptions options) =>
	const FileDeletingBuilder(['.happypass.part']);

Builder genBuilder([BuilderOptions options]) => _HappyPassBuilder();

class _HappyPassBuilder extends Builder {
	@override
	FutureOr<void> build(BuildStep buildStep) async {
		final inputId = buildStep.inputId;
		final library = await buildStep.inputLibrary.catchError((error) => null);
		if(library == null) {
			log.warning('${inputId.path} is not a completed dart source file(May be a part file), stop build this file');
			return;
		}
		final targetInput = inputId.changeExtension('.happypass.dart');
		final targetName = targetInput.pathSegments.last;
		// 第一步，检查 part 和 import
		final existPart = library.parts.map((unit) => unit.uri).contains(targetName);
		if(!existPart) {
			log.warning('${inputId.path} must declare: part: \'$targetName\';');
			return;
		}

		final existImport = library.imports.map((unit) => unit.uri).contains('package:happypass/happypass.dart');
		if(!existImport) {
			log.warning('${inputId.path} must declare: import: \'package:happypass/happypass.dart\';');
			return;
		}

		// 第二步，分析注解类
		// 只对顶级抽象类做分析，筛选
		final topClasses = library.topLevelElements.where((element) {
			// 选取顶级类，包括 Part File 中的顶级类
			if(element is ClassElement) {
				return element.isAbstract;
			}
			return false;
		}).map((element) => element as ClassElement);

		// 第三步，针对顶级类进行注解翻译
		// 注意，只有第一个生效
		for(var classElement in topClasses) {
			// 获取注解
			final annotations = classElement.metadata?.map((element) => element.computeConstantValue());
			if(annotations == null || annotations.isEmpty) {
				continue;
			}

			// 查找是否为 RequestFactory 注解
			final requestFactoryAnnotation = _findClassObj(objList: annotations, classType: RequestFactory);

			if(requestFactoryAnnotation != null) {
				// 注解为 RequestFactory
				await buildRequestFactory(_BuildContext(inputId, targetInput, buildStep, classElement));
				return;
			}

			// 查找是否为 RequestPrototype 注解
		}
	}

	@override
	Map<String, List<String>> get buildExtensions => const {
		'.dart': ['.happypass.dart']
	};
}

// 检查是否为该库中的类
bool _checkPackageClass({Element element, Type classType, List<Type> types}) {
	if(element == null || (classType == null && (types == null || types.isEmpty))) {
		return false;
	}

	final librarySource = element.librarySource;
	if(librarySource.uriKind == UriKind.PACKAGE_URI) {
		final uri = librarySource.uri;
		if(uri != null && uri.pathSegments != null && uri.pathSegments.isNotEmpty) {
			if(uri.pathSegments.first == 'happypass_builder') {
				if(types != null) {
					for(var classType in types) {
						final clsMirror = reflectClass(classType);
						if (clsMirror != null) {
							if (element.name == MirrorSystem.getName(clsMirror.simpleName)) {
								return true;
							}
						}
					}
				}
				else {
					final clsMirror = reflectClass(classType);
					if (clsMirror != null) {
						if (element.name == MirrorSystem.getName(clsMirror.simpleName)) {
							return true;
						}
					}
				}
			}
		}
	}
	return false;
}

DartObject _findClassObj({Iterable<DartObject> objList, Type classType, List<Type> types}) {
	if(objList == null || (classType == null && (types == null || types.isEmpty))) {
		return null;
	}

	for(var obj in objList) {
		if(_checkPackageClass(element: obj.type.element, classType: classType, types: types)) {
			return obj;
		}
	}
	return null;
}

/// 构建文件上下文
class _BuildContext {
    _BuildContext(this.inputId, this.outputId, this.buildStep, this.classElement);

	final AssetId inputId;
	final AssetId outputId;
	final BuildStep buildStep;
	final ClassElement classElement;
}

/// 暂时封装方法数据
class _MethodBundle {
    _MethodBundle({this.url, this.path, this.requestMethod, this.isFormData, this.isMultipart, this.method});

	final String url;
	final String path;
	final int requestMethod;
	final bool isFormData;
	final bool isMultipart;
	final MethodElement method;
}

/// 生成 RequestFactory 文件
Future<void> buildRequestFactory(_BuildContext buildContext) async {
	final inputId = buildContext.inputId;
	final outputId = buildContext.outputId;
	final buildStep = buildContext.buildStep;
	final classElement = buildContext.classElement;
	final className = buildContext.classElement.name;
	final concretedName = '_${className}';
	final methodList = <_MethodBundle>[];
	// 遍历 Methods, 找到注解为 Post / Get 的抽象方法
	for(var method in classElement.methods) {
		// 判断是否为抽象方法
		if(!method.isAbstract) {
			continue;
		}

		if(!method.returnType.isDartAsyncFuture) {
			// 没有找到 Request 注释类
			log.warning('$className - ${method.name} : return type must be Future');
			return;
		}

		// 获取注解
		final annotations = method.metadata?.map((element) => element.computeConstantValue());
		if(annotations == null || annotations.isEmpty) {
			continue;
		}

		final requestAnnotation = _findClassObj(objList: annotations, types: [Get, Post]);
		if(requestAnnotation == null) {
			// 没有找到 Request 注释类
			log.warning('$className - ${method.name} : need @Post / @Get annotation');
			return;
		}

		final url = requestAnnotation.getField('url')?.toStringValue();
		final path = requestAnnotation.getField('path')?.toStringValue();
		var isFormData = false;
		var isMultipart = false;
		int requestMethod;
		switch(requestAnnotation.type.element.name) {
			case 'Get':
				requestMethod = 0;
				break;
			case 'Post':
				requestMethod = 1;
				// 检测参数是否为空
				if(method.parameters == null || method.parameters.isEmpty) {
					// 没有找到 Request 注释类
					log.warning('$className - ${method.name} : parameters must not be null in post method');
					return;
				}
				isFormData = requestMethod == 0 ? false : _findClassObj(objList: annotations, classType: FormData) != null;
				isMultipart = requestMethod == 0 ? false : _findClassObj(objList: annotations, classType: Multipart) != null;
				if(method.parameters.length > 1 && !isFormData && !isMultipart) {
					isFormData = true;
				}
				break;
		}


		methodList.add(_MethodBundle(
			url: url,
			path: path,
			requestMethod: requestMethod,
			isFormData: isFormData,
			isMultipart: isMultipart,
			method: method
		));
	}

	final buffer = StringBuffer();
	buffer.writeln('/// Generate by happypass_builder, Don\'t change anything by manual');
	buffer.writeln('/// ################################################');
	buffer.writeln('/// Request Factory Implement of ${classElement.name}');
	buffer.writeln('/// ################################################');
	buffer.writeln('part of \'${inputId.pathSegments.last}\';');

	buffer.writeln('');
	buffer.writeln('$className generate$className({RequestPrototype prototype}) => $concretedName.requestPrototype(prototype);');
	buffer.writeln('');
	buffer.writeln('class $concretedName extends $className { // $concretedName start');
	buffer.writeln('');
	buffer.writeln('\t/// Default constructor, No request prototype');
	buffer.writeln('\t$concretedName(): _prototype = null;');
	buffer.writeln('');
	buffer.writeln('\t/// Create Request Factory with Request Prototype');
	buffer.writeln('\t$concretedName.requestPrototype(RequestPrototype prototype): _prototype = prototype;');
	buffer.writeln('');
	buffer.writeln('\tfinal RequestPrototype _prototype;');
	for(final bundle in methodList) {
		buffer.writeln('');
		final method = bundle.method;
		final methodName = method.name;
		buffer.writeln('\t@override');
		buffer.writeln('\t${method.getDisplayString(withNullability: false)} async {');
		switch(bundle.requestMethod) {
			// GET
			case 0:
				buffer.writeln('\t\tfinal result = await happypass.get(');
				buffer.writeln('\t\t\turl: ${bundle.url != null ? '\'${bundle.url}\'' : 'null'},');
				buffer.writeln('\t\t\tpath: ${bundle.path != null ? '\'${bundle.path}\'' : 'null'},');
				buffer.writeln('\t\t\tprototype: _prototype,');
				buffer.writeln('\t\t\tconfigCallback: (Request request) {');
				final params = method.parameters;
				if(params != null && params.isNotEmpty) {
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\t\t\tif($name != null) {');
						buffer.writeln('\t\t\t\t\trequest.appendQueryParams(\'$name\', $name.toString());');
						buffer.writeln('\t\t\t\t}');
					});
				}
				buffer.writeln('\t\t\t},');
				buffer.writeln('\t\t);');
				break;
			// POST
			case 1:
				final params = method.parameters;
				if(bundle.isFormData) {
					buffer.writeln('\t\tfinal body = FormDataBody();');
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\tbody.addPair(\'$name\', $name);');
					});
				}
				else if(bundle.isMultipart) {
					buffer.writeln('\t\tfinal body = MultipartDataBody();');
					params.forEach((param) {
						final name = param.name;
						buffer.writeln('\t\tif($name != null) {');
						final paramLib = param.type.element.librarySource;
						final scheme = paramLib?.uri?.scheme;
						final first = paramLib?.uri?.pathSegments?.first;
						print('first: $first, scheme: $scheme');
						if(scheme == 'dart' && (first == 'io' || first == 'html')) {
							buffer.writeln('\t\t\tbody.addMultipartFile(\'$name\', $name);');
						}
						else {
							buffer.writeln('\t\t\tbody.addMultipartText(\'$name\', $name.toString());');
						}
						buffer.writeln('\t\t}');
					});
				}
				else {
					if(params.length == 1) {
						buffer.writeln('\t\tfinal body = ${params[0].name};');
					}
					else {
						// FormData
						buffer.writeln('\t\tfinal body = FormDataBody();');
						params.forEach((param) {
							final name = param.name;
							buffer.writeln('\t\tbody.addPair(\'$name\', $name.toString());');
						});
					}
				}

				buffer.writeln('\t\tfinal result = await happypass.post(');
				buffer.writeln('\t\t\turl: ${bundle.url != null ? '\'${bundle.url}\'' : 'null'},');
				buffer.writeln('\t\t\tpath: ${bundle.path != null ? '\'${bundle.path}\'' : 'null'},');
				buffer.writeln('\t\t\tbody: body,');
				buffer.writeln('\t\t\tprototype: _prototype,');
				buffer.writeln('\t\t\tconfigCallback: (Request request) {');
				buffer.writeln('\t\t\t},');
				buffer.writeln('\t\t);');
				break;
		}
		final returnElem = method.returnType as InterfaceType;
		final typeArguments = returnElem.typeArguments;
		if(typeArguments == null || typeArguments.isEmpty) {
			buffer.writeln('\t\treturn result;');
		}
		else {
			final typeStr = typeArguments[0].getDisplayString();
			buffer.writeln('\t\tif(result is SuccessPassResponse && result.body is $typeStr) {');
			buffer.writeln('\t\t\treturn result.body as $typeStr;');
			buffer.writeln('\t\t}');
			buffer.writeln('\t\t');
			buffer.writeln('\t\treturn null;');
		}

		buffer.writeln('\t} // $methodName end');
	}
	buffer.writeln('} // $concretedName end');

	await buildStep.writeAsString(outputId, buffer.toString());
}
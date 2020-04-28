/// 为了防止歧义，建议在导入此文件时使用 `as`

/// Request Factory 注解类
class RequestFactory {
	const RequestFactory();
}


/// Post 请求方法
class Post {
	const Post({this.url, this.path});
	
	/// 请求地址
	final String url;
	
	/// 请求路径
	final String path;
}

/// Get 请求方法
class Get {
	const Get({this.url, this.path});
	
	/// 请求地址
	final String url;
	
	/// 请求路径
	final String path;
}

/// 表示请求体类型为 FormDataBody
class FormData {
	const FormData();
}

/// 表示请求体类型为 FormData-Multipart
class Multipart {
	const Multipart();
}

/// 表示采用 Utf8 String 进行数据的编解码
/// * 设置此选项会强制覆盖 RequestPrototype 配置的编解码器
class StringChannel {
	const StringChannel();
}

/// 表示采用 Utf8 String JSON 进行数据的编解码
/// * 设置此选项会强制覆盖 RequestPrototype 配置的编解码器
class JSONChannel {
	const JSONChannel();
}

/// 表示采用 RequestPrototype 中的编解码器进行数据的编解码
class RawChannel {
	const RawChannel();
}
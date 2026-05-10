<?php
// =============================================================================
// TFG Infraestructura Multi-Cloud - Formulario CRUD Gimnasio
// =============================================================================
// Operaciones:
//   - CREATE: Inscribir nuevo cliente con membresía
//   - READ:   Listar todos los clientes inscritos
//   - UPDATE: Modificar datos de un cliente existente
//   - DELETE: Eliminar un cliente
//
// Variables de entorno (se pasan con docker run -e):
//   DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, DB_PORT
// =============================================================================

$mensaje = "";
$tipo = "";

// --- Conexión a la base de datos ---
$db_host     = getenv("DB_HOST");
$db_user     = getenv("DB_USER");
$db_password = getenv("DB_PASSWORD");
$db_name     = getenv("DB_NAME");
$db_port     = getenv("DB_PORT") ?: 3306;

/**
 * Crea y devuelve una conexión MySQLi.
 * Se usa una función para poder reutilizarla en cada operación.
 */
function conectar($host, $user, $pass, $name, $port) {
    $conn = new mysqli($host, $user, $pass, $name, $port);
    if ($conn->connect_error) {
        return null;
    }
    $conn->set_charset("utf8mb4");
    return $conn;
}

// --- Procesar acciones del formulario ---
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $accion = $_POST["accion"] ?? "";
    $conexion = conectar($db_host, $db_user, $db_password, $db_name, $db_port);

    if (!$conexion) {
        $mensaje = "Error de conexión con la base de datos.";
        $tipo = "error";
    } else {
        // =====================================================================
        // CREATE - Inscribir nuevo cliente
        // =====================================================================
        if ($accion === "crear") {
            $dni       = trim($_POST["dni_cliente"]);
            $nombre    = trim($_POST["nombre"]);
            $edad      = intval($_POST["edad"]);
            $sexo      = $_POST["sexo"];
            $membresia = intval($_POST["id_membresia"]);
            // El recepcionista por defecto es '11111111A' (como en el ejemplo de Diego)
            $empleado  = "11111111A";

            try {
                $conexion->begin_transaction();

                $stmt = $conexion->prepare(
                    "INSERT INTO clientes (dni_cliente, nombre, edad, sexo) VALUES (?, ?, ?, ?)"
                );
                $stmt->bind_param("ssis", $dni, $nombre, $edad, $sexo);
                $stmt->execute();
                $stmt->close();

                $stmt = $conexion->prepare(
                    "INSERT INTO venta_alta (dni_cliente, dni_empleado, id_membresia, fecha) VALUES (?, ?, ?, CURDATE())"
                );
                $stmt->bind_param("ssi", $dni, $empleado, $membresia);
                $stmt->execute();
                $stmt->close();

                $conexion->commit();
                $mensaje = "Cliente inscrito correctamente.";
                $tipo = "ok";
            } catch (Exception $e) {
                $conexion->rollback();
                $mensaje = "Error al inscribir: " . $e->getMessage();
                $tipo = "error";
            }
        }

        // =====================================================================
        // UPDATE - Modificar datos de un cliente
        // =====================================================================
        elseif ($accion === "editar") {
            $dni    = trim($_POST["dni_cliente"]);
            $nombre = trim($_POST["nombre"]);
            $edad   = intval($_POST["edad"]);
            $sexo   = $_POST["sexo"];

            try {
                $stmt = $conexion->prepare(
                    "UPDATE clientes SET nombre = ?, edad = ?, sexo = ? WHERE dni_cliente = ?"
                );
                $stmt->bind_param("siss", $nombre, $edad, $sexo, $dni);
                $stmt->execute();

                if ($stmt->affected_rows > 0) {
                    $mensaje = "Cliente actualizado correctamente.";
                    $tipo = "ok";
                } else {
                    $mensaje = "No se encontró el cliente con DNI: $dni";
                    $tipo = "error";
                }
                $stmt->close();
            } catch (Exception $e) {
                $mensaje = "Error al actualizar: " . $e->getMessage();
                $tipo = "error";
            }
        }

        // =====================================================================
        // DELETE - Eliminar un cliente
        // =====================================================================
        elseif ($accion === "eliminar") {
            $dni = trim($_POST["dni_eliminar"]);

            try {
                // Primero eliminar registros dependientes (FK)
                $conexion->begin_transaction();

                // Eliminar entrenamientos del cliente
                $stmt = $conexion->prepare("DELETE FROM entrenan WHERE dni_cliente = ?");
                $stmt->bind_param("s", $dni);
                $stmt->execute();
                $stmt->close();

                // Eliminar ventas del cliente
                $stmt = $conexion->prepare("DELETE FROM venta_alta WHERE dni_cliente = ?");
                $stmt->bind_param("s", $dni);
                $stmt->execute();
                $stmt->close();

                // Eliminar el cliente
                $stmt = $conexion->prepare("DELETE FROM clientes WHERE dni_cliente = ?");
                $stmt->bind_param("s", $dni);
                $stmt->execute();

                if ($stmt->affected_rows > 0) {
                    $mensaje = "Cliente eliminado correctamente.";
                    $tipo = "ok";
                } else {
                    $mensaje = "No se encontró el cliente con DNI: $dni";
                    $tipo = "error";
                }
                $stmt->close();

                $conexion->commit();
            } catch (Exception $e) {
                $conexion->rollback();
                $mensaje = "Error al eliminar: " . $e->getMessage();
                $tipo = "error";
            }
        }

        $conexion->close();
    }
}

// --- Obtener lista de clientes (READ) ---
$clientes = [];
$conexion = conectar($db_host, $db_user, $db_password, $db_name, $db_port);
if ($conexion) {
    $result = $conexion->query(
        "SELECT c.dni_cliente, c.nombre, c.edad, c.sexo, m.nombre AS membresia, v.fecha
         FROM clientes c
         LEFT JOIN venta_alta v ON c.dni_cliente = v.dni_cliente
         LEFT JOIN membresias m ON v.id_membresia = m.id_membresia
         ORDER BY v.fecha DESC, c.nombre ASC"
    );
    if ($result) {
        while ($row = $result->fetch_assoc()) {
            $clientes[] = $row;
        }
        $result->free();
    }
    $conexion->close();
}
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gimnasio - Gestión de Clientes</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            background: #f0f2f5;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
        }
        h1 {
            text-align: center;
            margin-bottom: 20px;
            color: #1a1a2e;
        }
        h2 {
            margin-bottom: 15px;
            color: #16213e;
            border-bottom: 2px solid #0f3460;
            padding-bottom: 5px;
        }

        /* Mensajes de estado */
        .msg {
            padding: 12px;
            border-radius: 6px;
            margin-bottom: 20px;
            font-weight: bold;
        }
        .msg.ok { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .msg.error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }

        /* Secciones */
        .card {
            background: white;
            padding: 25px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            margin-bottom: 25px;
        }

        /* Formularios */
        label { font-weight: 600; display: block; margin-top: 12px; }
        input, select {
            width: 100%;
            padding: 10px;
            margin-top: 4px;
            border: 1px solid #ccc;
            border-radius: 4px;
            font-size: 14px;
        }
        input:focus, select:focus {
            border-color: #0f3460;
            outline: none;
            box-shadow: 0 0 3px rgba(15,52,96,0.3);
        }
        button {
            width: 100%;
            padding: 12px;
            margin-top: 18px;
            border: none;
            border-radius: 4px;
            font-size: 15px;
            font-weight: bold;
            cursor: pointer;
            transition: background 0.2s;
        }
        .btn-crear { background: #0f3460; color: white; }
        .btn-crear:hover { background: #16213e; }
        .btn-editar { background: #e67e22; color: white; }
        .btn-editar:hover { background: #d35400; }
        .btn-eliminar { background: #e74c3c; color: white; padding: 6px 14px; width: auto; margin: 0; font-size: 13px; }
        .btn-eliminar:hover { background: #c0392b; }

        /* Tabla de clientes */
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
        }
        th {
            background: #0f3460;
            color: white;
            padding: 10px;
            text-align: left;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #eee;
        }
        tr:hover { background: #f5f6fa; }

        /* Layout dos columnas para los formularios */
        .forms-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 25px;
        }
        @media (max-width: 700px) {
            .forms-grid { grid-template-columns: 1fr; }
        }

        .nota {
            font-size: 12px;
            color: #888;
            text-align: center;
            margin-top: 20px;
        }
        .info-cloud {
            text-align: center;
            font-size: 13px;
            color: #666;
            background: #eef;
            padding: 8px;
            border-radius: 4px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
<div class="container">
    <h1>Gimnasio - Gestión de Clientes</h1>

    <div class="info-cloud">
        Conectado a: <strong><?php echo htmlspecialchars($db_host ?: "No configurado"); ?></strong>
        | Base de datos: <strong><?php echo htmlspecialchars($db_name ?: "N/A"); ?></strong>
    </div>

    <?php if ($mensaje !== ""): ?>
        <div class="msg <?php echo $tipo; ?>">
            <?php echo htmlspecialchars($mensaje); ?>
        </div>
    <?php endif; ?>

    <!-- ================================================================= -->
    <!-- FORMULARIOS: CREAR + EDITAR                                       -->
    <!-- ================================================================= -->
    <div class="forms-grid">
        <!-- CREAR nuevo cliente -->
        <div class="card">
            <h2>Inscribir Cliente</h2>
            <form method="POST">
                <input type="hidden" name="accion" value="crear">

                <label>DNI del cliente</label>
                <input type="text" name="dni_cliente" maxlength="20" required
                       placeholder="Ej: 12345678A">

                <label>Nombre completo</label>
                <input type="text" name="nombre" required
                       placeholder="Ej: Juan Pérez">

                <label>Edad</label>
                <input type="number" name="edad" min="0" max="120" required>

                <label>Sexo</label>
                <select name="sexo">
                    <option value="Hombre">Hombre</option>
                    <option value="Mujer">Mujer</option>
                    <option value="Otro">Otro</option>
                    <option value="No especificado">No especificado</option>
                </select>

                <label>Membresía</label>
                <select name="id_membresia" required>
                    <option value="1">Básica - 29.99€</option>
                    <option value="2">Premium - 49.99€</option>
                    <option value="3">VIP - 79.99€</option>
                </select>

                <button type="submit" class="btn-crear">Inscribir</button>
            </form>
        </div>

        <!-- EDITAR cliente existente -->
        <div class="card">
            <h2>Editar Cliente</h2>
            <form method="POST">
                <input type="hidden" name="accion" value="editar">

                <label>DNI del cliente a editar</label>
                <input type="text" name="dni_cliente" maxlength="20" required
                       placeholder="DNI existente">

                <label>Nuevo nombre</label>
                <input type="text" name="nombre" required
                       placeholder="Nombre actualizado">

                <label>Nueva edad</label>
                <input type="number" name="edad" min="0" max="120" required>

                <label>Nuevo sexo</label>
                <select name="sexo">
                    <option value="Hombre">Hombre</option>
                    <option value="Mujer">Mujer</option>
                    <option value="Otro">Otro</option>
                    <option value="No especificado">No especificado</option>
                </select>

                <button type="submit" class="btn-editar">Actualizar</button>
            </form>
        </div>
    </div>

    <!-- ================================================================= -->
    <!-- TABLA: LISTAR CLIENTES (READ) + ELIMINAR (DELETE)                 -->
    <!-- ================================================================= -->
    <div class="card">
        <h2>Clientes Inscritos (<?php echo count($clientes); ?>)</h2>

        <?php if (empty($clientes)): ?>
            <p style="color: #888; text-align: center; padding: 20px;">
                No hay clientes registrados todavía.
            </p>
        <?php else: ?>
            <table>
                <thead>
                    <tr>
                        <th>DNI</th>
                        <th>Nombre</th>
                        <th>Edad</th>
                        <th>Sexo</th>
                        <th>Membresía</th>
                        <th>Fecha Alta</th>
                        <th>Acción</th>
                    </tr>
                </thead>
                <tbody>
                    <?php foreach ($clientes as $c): ?>
                    <tr>
                        <td><?php echo htmlspecialchars($c['dni_cliente']); ?></td>
                        <td><?php echo htmlspecialchars($c['nombre']); ?></td>
                        <td><?php echo htmlspecialchars($c['edad']); ?></td>
                        <td><?php echo htmlspecialchars($c['sexo']); ?></td>
                        <td><?php echo htmlspecialchars($c['membresia'] ?? 'Sin membresía'); ?></td>
                        <td><?php echo htmlspecialchars($c['fecha'] ?? '-'); ?></td>
                        <td>
                            <form method="POST" style="display:inline;"
                                  onsubmit="return confirm('¿Eliminar a <?php echo htmlspecialchars($c['nombre']); ?>?');">
                                <input type="hidden" name="accion" value="eliminar">
                                <input type="hidden" name="dni_eliminar"
                                       value="<?php echo htmlspecialchars($c['dni_cliente']); ?>">
                                <button type="submit" class="btn-eliminar">Eliminar</button>
                            </form>
                        </td>
                    </tr>
                    <?php endforeach; ?>
                </tbody>
            </table>
        <?php endif; ?>
    </div>

    <p class="nota">
        TFG Infraestructura Multi-Cloud | Los datos se almacenan en Amazon RDS MySQL.
    </p>
</div>
</body>
</html>
